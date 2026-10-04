package com.workvault.work_vault

import android.os.SystemClock
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Base64
import javax.net.ssl.SSLException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive

/**
 * TUS 1.0.0 upload session.
 *
 * Creation (`POST`), offset discovery (`HEAD`), and chunk upload (`PATCH`) follow the core
 * protocol. When the server advertises the checksum extension, each `PATCH` carries
 * `Upload-Checksum: sha256 <base64>`. A stored location is reused after process death.
 */
internal class TusProtocolHandler(
    private val workerStopped: () -> Boolean,
    private val onProgress: suspend (TransferProgressUpdate) -> Unit,
    private val quotaYield: suspend () -> Boolean,
) {
    suspend fun upload(record: TaskRecord, foreground: Boolean, sessionStartMs: Long?): DownloadOutcome {
        val config = record.config
        val source = File(config.destinationPath)
        if (!source.isFile) {
            return DownloadOutcome.Failed("io", "The upload source file was not found.", null, false)
        }
        val length = source.length()
        val expectedSha = normalizeHexDigest(headerValue(config.headers, ChecksumVerifier.expectedSha256Header), 32)
        val expectedMd5 = normalizeHexDigest(headerValue(config.headers, ChecksumVerifier.expectedMd5Header), 16)
        var location = record.tusLocation
        var offset = record.uploadOffset.coerceAtLeast(0L).coerceAtMost(length)
        val runStarted = SystemClock.elapsedRealtime()
        var speed = record.bytesPerSecond.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0
        var lastTick = runStarted
        var lastBytes = offset
        return try {
            val creationUrl = URL(config.url)
            val extensions = discoverExtensions(config, creationUrl)
            if (location == null) {
                location = createUpload(config, creationUrl, length, extensions)
                offset = 0L
                publish(config, offset, length, speed, record.elapsedMs, runStarted, location, expectedSha, expectedMd5)
            }
            val uploadUrl = URL(creationUrl, location)
            offset = headOffset(config, uploadUrl) ?: offset
            if (offset > length) {
                return DownloadOutcome.Failed("tus", "The server offset is past the end of the local file.", null, false)
            }
            if (offset == length) {
                publish(config, offset, length, speed, record.elapsedMs, runStarted, location, expectedSha, expectedMd5)
                return DownloadOutcome.Completed
            }
            val checksums = extensions.contains(CHECKSUM_EXTENSION)
            RandomAccessFile(source, "r").use { input ->
                while (offset < length) {
                    coroutineContext.ensureActive()
                    stopReason(config.taskId)?.let { return@use it }
                    val elapsed = SystemClock.elapsedRealtime() - runStarted
                    if (!foreground && elapsed >= WorkVaultContract.chunkBudgetMs && offset > record.uploadOffset) {
                        return@use DownloadOutcome.Yielded
                    }
                    if (foreground && sessionStartMs != null && quotaYield()) {
                        return@use DownloadOutcome.Yielded
                    }
                    val count = minOf(WorkVaultContract.chunkBytes, length - offset)
                    val patch = patchChunk(config, uploadUrl, input, offset, count, checksums)
                    if (patch.conflict) {
                        val serverOffset = headOffset(config, uploadUrl)
                        if (serverOffset == null || serverOffset == offset) {
                            return@use DownloadOutcome.Failed("tus", "The upload offset was rejected.", 409, true)
                        }
                        offset = serverOffset
                        continue
                    }
                    offset = patch.offset
                    val nowTick = SystemClock.elapsedRealtime()
                    val deltaMs = nowTick - lastTick
                    if (deltaMs > 0L) {
                        val instant = (offset - lastBytes) * 1000.0 / deltaMs
                        speed = if (speed <= 0.0) instant else speed * 0.7 + instant * 0.3
                        lastTick = nowTick
                        lastBytes = offset
                    }
                    publish(config, offset, length, speed, record.elapsedMs, runStarted, location, expectedSha, expectedMd5)
                    if (!foreground && offset < length) {
                        return@use DownloadOutcome.Yielded
                    }
                }
            }
            DownloadOutcome.Completed
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (ssl: SSLException) {
            DownloadOutcome.Failed("tls", ssl.message ?: "The TLS handshake failed.", null, true)
        } catch (error: TransferException) {
            DownloadOutcome.Failed(error.code, error.message, error.httpStatus, error.retryable)
        } catch (error: IOException) {
            stopReason(config.taskId) ?: if (offset > record.uploadOffset) {
                DownloadOutcome.Yielded
            } else {
                DownloadOutcome.Failed(
                    "io",
                    error.message ?: "The upload was interrupted.",
                    null,
                    true,
                )
            }
        }
    }

    private fun discoverExtensions(config: WorkTaskConfig, url: URL): Set<String> {
        val connection = openHttps(config.taskId, url, "OPTIONS", protocolHeaders(config)) {
            setRequestProperty(TUS_RESUMABLE, TUS_VERSION)
        }
        return try {
            if (connection.responseCode >= 400) {
                emptySet()
            } else {
                parseListHeader(connection.getHeaderField("Tus-Extension"))
            }
        } finally {
            WorkVaultSignals.unbind(config.taskId, connection)
            connection.disconnect()
        }
    }

    private fun createUpload(config: WorkTaskConfig, url: URL, length: Long, extensions: Set<String>): String {
        if (!extensions.contains(CREATION_EXTENSION) && extensions.isNotEmpty()) {
            throw TransferException("tus", "The server does not advertise the creation extension.", null, false)
        }
        val metadata = encodeTusMetadata(uploadMetadata(config))
        val connection = openHttps(config.taskId, url, "POST", protocolHeaders(config)) {
            setRequestProperty(TUS_RESUMABLE, TUS_VERSION)
            setRequestProperty("Upload-Length", length.toString())
            if (metadata.isNotEmpty()) {
                setRequestProperty("Upload-Metadata", metadata)
            }
            doOutput = true
            setFixedLengthStreamingMode(0)
        }
        try {
            val code = connection.responseCode
            if (code != 201 && code != 204) {
                throw TransferException("tus", "Upload creation failed with HTTP $code.", code, code >= 500)
            }
            val location = connection.getHeaderField("Location")
            if (location.isNullOrBlank()) {
                throw TransferException("tus", "Upload creation did not return a Location.", code, false)
            }
            return location
        } finally {
            WorkVaultSignals.unbind(config.taskId, connection)
            connection.disconnect()
        }
    }

    private fun headOffset(config: WorkTaskConfig, url: URL): Long? {
        val connection = openHttps(config.taskId, url, "HEAD", protocolHeaders(config)) {
            setRequestProperty(TUS_RESUMABLE, TUS_VERSION)
        }
        try {
            val code = connection.responseCode
            if (code == 404 || code == 410) {
                throw TransferException("tus", "The upload session no longer exists.", code, false)
            }
            if (code >= 400) {
                throw TransferException("tus", "Upload offset lookup failed with HTTP $code.", code, code >= 500)
            }
            return parseUploadOffset(connection.getHeaderField("Upload-Offset"))
        } finally {
            WorkVaultSignals.unbind(config.taskId, connection)
            connection.disconnect()
        }
    }

    private fun patchChunk(
        config: WorkTaskConfig,
        url: URL,
        input: RandomAccessFile,
        offset: Long,
        count: Long,
        checksums: Boolean,
    ): PatchResult {
        val payload = ByteArray(count.toInt())
        input.seek(offset)
        input.readFully(payload)
        val digest = if (checksums) MessageDigest.getInstance("SHA-256").digest(payload) else null
        val connection = openHttps(
            taskId = config.taskId,
            initial = url,
            method = "PATCH",
            headers = protocolHeaders(config),
            writeBody = { active ->
                active.outputStream.use { stream -> writeFully(stream, payload) }
            },
        ) {
            setRequestProperty(TUS_RESUMABLE, TUS_VERSION)
            setRequestProperty("Upload-Offset", offset.toString())
            setRequestProperty("Content-Type", OFFSET_CONTENT_TYPE)
            if (digest != null) {
                setRequestProperty("Upload-Checksum", uploadChecksumHeader("sha256", digest))
            }
            doOutput = true
            setFixedLengthStreamingMode(payload.size)
        }
        try {
            val code = connection.responseCode
            if (code == 409) {
                return PatchResult(offset = offset, conflict = true)
            }
            if (code == 460) {
                throw TransferException("checksum", "The server rejected the upload checksum.", code, false)
            }
            if (code != 204 && code != 200) {
                throw TransferException("tus", "Chunk upload failed with HTTP $code.", code, code == 408 || code == 429 || code >= 500)
            }
            val acknowledged = parseUploadOffset(connection.getHeaderField("Upload-Offset")) ?: (offset + count)
            return PatchResult(offset = acknowledged, conflict = false)
        } finally {
            WorkVaultSignals.unbind(config.taskId, connection)
            connection.disconnect()
        }
    }

    private suspend fun publish(
        config: WorkTaskConfig,
        offset: Long,
        length: Long,
        speed: Double,
        baseElapsed: Long,
        runStarted: Long,
        location: String?,
        expectedSha256: String?,
        expectedMd5: String?,
    ) {
        val elapsed = baseElapsed + (SystemClock.elapsedRealtime() - runStarted)
        onProgress(
            TransferProgressUpdate(
                bytes = offset,
                totalBytes = length,
                bytesPerSecond = speed,
                elapsedMs = elapsed.coerceAtLeast(0L),
                acceptsRanges = null,
                etag = null,
                expectedSha256 = expectedSha256,
                expectedMd5 = expectedMd5,
                tusLocation = location,
                uploadOffset = offset,
            ),
        )
    }

    private fun stopReason(taskId: String): DownloadOutcome? {
        return when (WorkVaultSignals.desired(taskId)) {
            TaskStatus.PAUSED -> DownloadOutcome.Paused
            TaskStatus.CANCELLED -> DownloadOutcome.Cancelled
            TaskStatus.COMPLETED, TaskStatus.FAILED -> DownloadOutcome.Stopped
            TaskStatus.ENQUEUED, TaskStatus.RUNNING, null -> when {
                WorkVaultSignals.yieldRequested(taskId) -> DownloadOutcome.Yielded
                workerStopped() -> DownloadOutcome.Stopped
                else -> null
            }
        }
    }

    private fun protocolHeaders(config: WorkTaskConfig): Map<String, String> = wireHeaders(config.headers)
}

internal fun isTusUpload(config: WorkTaskConfig): Boolean {
    if (config.method != HttpMethod.POST && config.method != HttpMethod.PUT) {
        return false
    }
    if (headerValue(config.headers, "Tus-Resumable") == TUS_VERSION) {
        return true
    }
    return headerValue(config.headers, "Upload-Metadata") != null
}

internal fun encodeTusMetadata(entries: Map<String, String>): String {
    if (entries.isEmpty()) {
        return ""
    }
    return entries.entries.joinToString(",") { (key, value) ->
        val encoded = Base64.getEncoder().encodeToString(value.toByteArray(Charsets.UTF_8))
        "$key $encoded"
    }
}

internal fun uploadMetadata(config: WorkTaskConfig): Map<String, String> {
    val explicit = headerValue(config.headers, "Upload-Metadata")
    if (explicit != null) {
        return parseTusMetadata(explicit)
    }
    val name = File(config.destinationPath).name
    return if (name.isEmpty()) emptyMap() else mapOf("filename" to name)
}

internal fun parseTusMetadata(header: String): Map<String, String> {
    val decoded = linkedMapOf<String, String>()
    for (part in header.split(',')) {
        val piece = part.trim()
        if (piece.isEmpty()) {
            continue
        }
        val space = piece.indexOf(' ')
        if (space <= 0) {
            decoded[piece] = ""
            continue
        }
        val key = piece.substring(0, space).trim()
        val value = piece.substring(space + 1).trim()
        decoded[key] = try {
            String(Base64.getDecoder().decode(value), Charsets.UTF_8)
        } catch (_: IllegalArgumentException) {
            ""
        }
    }
    return decoded
}

internal fun parseListHeader(header: String?): Set<String> {
    if (header.isNullOrBlank()) {
        return emptySet()
    }
    return header.split(',')
        .map { it.trim().lowercase() }
        .filter { it.isNotEmpty() }
        .toSet()
}

internal fun parseUploadOffset(header: String?): Long? {
    return header?.trim()?.toLongOrNull()?.takeIf { it >= 0L }
}

internal fun uploadChecksumHeader(algorithm: String, rawDigest: ByteArray): String {
    return "$algorithm ${Base64.getEncoder().encodeToString(rawDigest)}"
}

internal fun sha256HexFromDigestHeader(header: String?): String? {
    if (header.isNullOrBlank()) {
        return null
    }
    for (part in header.split(',')) {
        val piece = part.trim()
        val separator = piece.indexOf('=')
        if (separator <= 0) {
            continue
        }
        val algorithm = piece.substring(0, separator).trim()
        if (!algorithm.equals("sha-256", ignoreCase = true)) {
            continue
        }
        val wrapped = piece.substring(separator + 1).trim().removePrefix(":").removeSuffix(":")
        val raw = try {
            Base64.getDecoder().decode(wrapped)
        } catch (_: IllegalArgumentException) {
            null
        } ?: continue
        if (raw.size == 32) {
            return raw.toHex()
        }
    }
    return null
}

internal fun md5HexFromContentMd5(header: String?): String? {
    if (header.isNullOrBlank()) {
        return null
    }
    val raw = try {
        Base64.getDecoder().decode(header.trim())
    } catch (_: IllegalArgumentException) {
        return null
    }
    if (raw.size != 16) {
        return null
    }
    return raw.toHex()
}

internal fun normalizeHexDigest(value: String?, bytes: Int): String? {
    if (value == null) {
        return null
    }
    val hex = value.trim().lowercase()
    if (hex.length != bytes * 2 || hex.any { it !in '0'..'9' && it !in 'a'..'f' }) {
        return null
    }
    return hex
}

private fun writeFully(stream: OutputStream, payload: ByteArray) {
    stream.write(payload)
    stream.flush()
}

private data class PatchResult(val offset: Long, val conflict: Boolean)

private const val TUS_VERSION = "1.0.0"
private const val TUS_RESUMABLE = "Tus-Resumable"
private const val CREATION_EXTENSION = "creation"
private const val CHECKSUM_EXTENSION = "checksum"
private const val OFFSET_CONTENT_TYPE = "application/offset+octet-stream"
