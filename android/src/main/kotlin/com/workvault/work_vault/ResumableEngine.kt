package com.workvault.work_vault

import android.os.SystemClock
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import javax.net.ssl.SSLException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive

/**
 * Resumable HTTPS GET.
 *
 * A 206 response is appended only when `Content-Range` starts at the bytes already on disk.
 * `Accept-Ranges`, `ETag`, and `If-Range` decide whether the next attempt can continue.
 * A dropped connection keeps the bytes already synced and yields so the next run resumes.
 */
internal class ResumableEngine(
    private val workerStopped: () -> Boolean,
    private val onProgress: suspend (TransferProgressUpdate) -> Unit,
    private val quotaYield: suspend () -> Boolean,
) {
    suspend fun download(record: TaskRecord, foreground: Boolean, sessionStartMs: Long?): DownloadOutcome {
        val config = record.config
        val destination = File(config.destinationPath)
        val parent = destination.parentFile
        if (parent != null && !parent.isDirectory && !parent.mkdirs()) {
            return DownloadOutcome.Failed("io", "Could not create the destination directory.", null, false)
        }
        if (destination.isDirectory) {
            return DownloadOutcome.Failed("io", "destinationPath is a directory.", null, false)
        }
        val expectedSha = normalizeHexDigest(headerValue(config.headers, ChecksumVerifier.expectedSha256Header), 32)
        val expectedMd5 = normalizeHexDigest(headerValue(config.headers, ChecksumVerifier.expectedMd5Header), 16)
        if (headerValue(config.headers, ChecksumVerifier.expectedSha256Header) != null && expectedSha == null) {
            return DownloadOutcome.Failed("checksum", "X-Work-Vault-Sha256 is not a SHA-256 hex digest.", null, false)
        }
        if (headerValue(config.headers, ChecksumVerifier.expectedMd5Header) != null && expectedMd5 == null) {
            return DownloadOutcome.Failed("checksum", "X-Work-Vault-Md5 is not an MD5 hex digest.", null, false)
        }
        var startOffset = if (destination.isFile) destination.length() else 0L
        var offset = startOffset
        var total = record.totalBytes
        var speed = record.bytesPerSecond.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0
        var rangeHonored = record.acceptsRanges != false
        var reportedRanges: Boolean? = record.acceptsRanges
        var etag = record.etag
        var responseSha = resolveExpectedDigest(expectedSha, null, record.expectedSha256)
        var responseMd5 = resolveExpectedDigest(expectedMd5, null, record.expectedMd5)
        val runStarted = SystemClock.elapsedRealtime()
        var lastTick = runStarted
        var lastBytes = offset
        return try {
            RandomAccessFile(destination, "rw").use { output ->
                while (true) {
                    coroutineContext.ensureActive()
                    stopReason(config.taskId)?.let {
                        syncAndPublish(output, config.taskId, offset, total, speed, record.elapsedMs, runStarted, reportedRanges, etag, responseSha, responseMd5)
                        return@use it
                    }
                    if (!foreground && SystemClock.elapsedRealtime() - runStarted >= WorkVaultContract.chunkBudgetMs && offset > startOffset) {
                        output.fd.sync()
                        publish(config.taskId, offset, total, speed, record.elapsedMs, runStarted, reportedRanges, etag, responseSha, responseMd5)
                        return@use DownloadOutcome.Yielded
                    }
                    if (foreground && sessionStartMs != null && quotaYield()) {
                        output.fd.sync()
                        publish(config.taskId, offset, total, speed, record.elapsedMs, runStarted, reportedRanges, etag, responseSha, responseMd5)
                        return@use DownloadOutcome.Yielded
                    }
                    val inclusiveEnd = if (!foreground && rangeHonored) offset + WorkVaultContract.chunkBytes - 1L else null
                    val sentRange = inclusiveEnd != null || offset > 0L
                    val connection = open(config, offset, inclusiveEnd, etag)
                    try {
                        val code = connection.responseCode
                        val observedEtag = normalizeEntityTag(connection.getHeaderField("ETag")) ?: etag
                        val contentRange = parseContentRange(connection.getHeaderField("Content-Range"))
                        val accept = connection.getHeaderField("Accept-Ranges")
                        responseSha = resolveExpectedDigest(
                            expectedSha,
                            sha256HexFromDigestHeader(connection.getHeaderField("Digest")),
                            responseSha,
                        )
                        responseMd5 = resolveExpectedDigest(
                            expectedMd5,
                            md5HexFromContentMd5(connection.getHeaderField("Content-MD5")),
                            responseMd5,
                        )
                        when (acceptsByteRanges(accept)) {
                            true -> {
                                rangeHonored = true
                                reportedRanges = true
                            }
                            false -> {
                                rangeHonored = false
                                reportedRanges = false
                            }
                            null -> Unit
                        }
                        if (code != 200 && code != 206 && code != 416) {
                            return@use httpFailure(code)
                        }
                        val plan = planPartialBody(
                            status = code,
                            requestedOffset = offset,
                            sentRange = sentRange,
                            contentRange = contentRange,
                            previousEtag = etag,
                            responseEtag = observedEtag,
                        )
                        etag = observedEtag
                        when (plan) {
                            PartialBodyPlan.COMPLETE -> {
                                output.fd.sync()
                                publish(config.taskId, offset, total, speed, record.elapsedMs, runStarted, reportedRanges, etag, responseSha, responseMd5)
                                return@use DownloadOutcome.Completed
                            }
                            PartialBodyPlan.REJECT -> return@use DownloadOutcome.Failed(
                                "range",
                                "The server returned a byte range that does not match the bytes on disk.",
                                code,
                                false,
                            )
                            PartialBodyPlan.RESTART -> {
                                rangeHonored = false
                                reportedRanges = false
                                output.setLength(0L)
                                offset = 0L
                                startOffset = 0L
                                if (code != 200) {
                                    publish(config.taskId, offset, total, speed, record.elapsedMs, runStarted, reportedRanges, etag, responseSha, responseMd5)
                                    return@use DownloadOutcome.Yielded
                                }
                            }
                            PartialBodyPlan.APPEND -> Unit
                        }
                        if (code == 206) {
                            rangeHonored = true
                            reportedRanges = true
                        }
                        total = contentRange?.total ?: resolveTotal(connection, code, offset) ?: total
                        val body = readBody(
                            taskId = config.taskId,
                            connection = connection,
                            output = output,
                            offset = offset,
                            total = total,
                            startOffset = startOffset,
                            speed = speed,
                            lastTick = lastTick,
                            lastBytes = lastBytes,
                            baseElapsed = record.elapsedMs,
                            runStarted = runStarted,
                            foreground = foreground,
                            rangeHonored = rangeHonored,
                            reportedRanges = reportedRanges,
                            etag = etag,
                            expectedSha256 = responseSha,
                            expectedMd5 = responseMd5,
                        )
                        offset = body.offset
                        total = body.total
                        speed = body.speed
                        lastTick = body.lastTick
                        lastBytes = body.lastBytes
                        reportedRanges = body.reportedRanges
                        output.fd.sync()
                        val finished = body.outcome
                        if (finished != null) {
                            return@use finished
                        }
                    } finally {
                        WorkVaultSignals.unbind(config.taskId, connection)
                        connection.disconnect()
                    }
                }
                @Suppress("UNREACHABLE_CODE")
                DownloadOutcome.Failed("io", "The download ended without a result.", null, true)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (timeout: SocketTimeoutException) {
            recoverFromConnectionLoss(offset - startOffset, stopReason(config.taskId), timeout.message)
        } catch (ssl: SSLException) {
            DownloadOutcome.Failed("tls", ssl.message ?: "The TLS handshake failed.", null, true)
        } catch (error: TransferException) {
            DownloadOutcome.Failed(error.code, error.message, error.httpStatus, error.retryable)
        } catch (error: IOException) {
            recoverFromConnectionLoss(offset - startOffset, stopReason(config.taskId), error.message)
        }
    }

    private suspend fun readBody(
        taskId: String,
        connection: HttpURLConnection,
        output: RandomAccessFile,
        offset: Long,
        total: Long?,
        startOffset: Long,
        speed: Double,
        lastTick: Long,
        lastBytes: Long,
        baseElapsed: Long,
        runStarted: Long,
        foreground: Boolean,
        rangeHonored: Boolean,
        reportedRanges: Boolean?,
        etag: String?,
        expectedSha256: String?,
        expectedMd5: String?,
    ): BodyProgress {
        var cursor = offset
        var knownTotal = total
        var currentSpeed = speed
        var tick = lastTick
        var bytesAtTick = lastBytes
        var ranges = reportedRanges
        output.seek(cursor)
        try {
            connection.inputStream.use { input ->
                val buffer = ByteArray(WorkVaultContract.readBufferBytes)
                var sinceSync = 0
                while (true) {
                    coroutineContext.ensureActive()
                    stopReason(taskId)?.let { reason ->
                        publish(taskId, cursor, knownTotal, currentSpeed, baseElapsed, runStarted, ranges, etag, expectedSha256, expectedMd5)
                        return BodyProgress(cursor, knownTotal, currentSpeed, tick, bytesAtTick, ranges, reason)
                    }
                    if (!foreground && rangeHonored && cursor - startOffset >= WorkVaultContract.chunkBytes) {
                        val done = knownTotal != null && cursor >= knownTotal
                        publish(taskId, cursor, knownTotal, currentSpeed, baseElapsed, runStarted, ranges, etag, expectedSha256, expectedMd5)
                        return BodyProgress(
                            cursor,
                            knownTotal,
                            currentSpeed,
                            tick,
                            bytesAtTick,
                            ranges,
                            if (done) DownloadOutcome.Completed else DownloadOutcome.Yielded,
                        )
                    }
                    if (!foreground && SystemClock.elapsedRealtime() - runStarted >= WorkVaultContract.chunkBudgetMs && cursor > startOffset) {
                        publish(taskId, cursor, knownTotal, currentSpeed, baseElapsed, runStarted, ranges, etag, expectedSha256, expectedMd5)
                        return BodyProgress(cursor, knownTotal, currentSpeed, tick, bytesAtTick, ranges, DownloadOutcome.Yielded)
                    }
                    val read = input.read(buffer)
                    if (read < 0) {
                        val outcome = endOfBody(cursor, startOffset, knownTotal, foreground, rangeHonored)
                        publish(taskId, cursor, knownTotal, currentSpeed, baseElapsed, runStarted, ranges, etag, expectedSha256, expectedMd5)
                        return BodyProgress(cursor, knownTotal, currentSpeed, tick, bytesAtTick, ranges, outcome)
                    }
                    output.write(buffer, 0, read)
                    cursor += read
                    sinceSync += read
                    if (sinceSync >= WorkVaultContract.syncEveryBytes) {
                        output.fd.sync()
                        sinceSync = 0
                    }
                    val nowTick = SystemClock.elapsedRealtime()
                    val deltaMs = nowTick - tick
                    if (deltaMs >= WorkVaultContract.progressIntervalMs) {
                        val instant = (cursor - bytesAtTick) * 1000.0 / deltaMs
                        currentSpeed = if (currentSpeed <= 0.0) instant else currentSpeed * 0.7 + instant * 0.3
                        tick = nowTick
                        bytesAtTick = cursor
                        publish(taskId, cursor, knownTotal, currentSpeed, baseElapsed, runStarted, ranges, etag, expectedSha256, expectedMd5)
                        if (foreground && quotaYield()) {
                            return BodyProgress(cursor, knownTotal, currentSpeed, tick, bytesAtTick, ranges, DownloadOutcome.Yielded)
                        }
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: IOException) {
            output.fd.sync()
            publish(taskId, cursor, knownTotal, currentSpeed, baseElapsed, runStarted, ranges, etag, expectedSha256, expectedMd5)
            return BodyProgress(
                cursor,
                knownTotal,
                currentSpeed,
                tick,
                bytesAtTick,
                ranges,
                recoverFromConnectionLoss(cursor - startOffset, stopReason(taskId), error.message),
            )
        }
    }

    private fun open(config: WorkTaskConfig, offset: Long, inclusiveEnd: Long?, etag: String?): HttpURLConnection {
        return openHttps(
            taskId = config.taskId,
            initial = URL(config.url),
            method = "GET",
            headers = wireHeaders(config.headers),
        ) {
            val range = when {
                inclusiveEnd != null -> "bytes=$offset-$inclusiveEnd"
                offset > 0L -> "bytes=$offset-"
                else -> null
            }
            if (range != null) {
                setRequestProperty("Range", range)
            }
            if (offset > 0L && etag != null) {
                setRequestProperty("If-Range", etag)
            }
        }
    }

    private suspend fun syncAndPublish(
        output: RandomAccessFile,
        taskId: String,
        bytes: Long,
        total: Long?,
        speed: Double,
        baseElapsed: Long,
        runStarted: Long,
        ranges: Boolean?,
        etag: String?,
        expectedSha256: String?,
        expectedMd5: String?,
    ) {
        output.fd.sync()
        publish(taskId, bytes, total, speed, baseElapsed, runStarted, ranges, etag, expectedSha256, expectedMd5)
    }

    private suspend fun publish(
        taskId: String,
        bytes: Long,
        total: Long?,
        speed: Double,
        baseElapsed: Long,
        runStarted: Long,
        ranges: Boolean?,
        etag: String?,
        expectedSha256: String?,
        expectedMd5: String?,
    ) {
        val elapsed = baseElapsed + (SystemClock.elapsedRealtime() - runStarted)
        onProgress(
            TransferProgressUpdate(
                bytes = bytes,
                totalBytes = total,
                bytesPerSecond = speed,
                elapsedMs = elapsed.coerceAtLeast(0L),
                acceptsRanges = ranges,
                etag = etag,
                expectedSha256 = expectedSha256,
                expectedMd5 = expectedMd5,
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
}

private class BodyProgress(
    val offset: Long,
    val total: Long?,
    val speed: Double,
    val lastTick: Long,
    val lastBytes: Long,
    val reportedRanges: Boolean?,
    val outcome: DownloadOutcome?,
)

internal data class ContentRange(
    val start: Long?,
    val endInclusive: Long?,
    val total: Long?,
)

internal enum class PartialBodyPlan {
    APPEND,
    RESTART,
    COMPLETE,
    REJECT,
}

internal fun parseContentRange(header: String?): ContentRange? {
    if (header.isNullOrBlank()) {
        return null
    }
    val value = header.trim()
    if (!value.startsWith("bytes", ignoreCase = true)) {
        return null
    }
    val spec = value.substring(5).trim()
    val slash = spec.lastIndexOf('/')
    if (slash < 0) {
        return null
    }
    val totalPart = spec.substring(slash + 1).trim()
    val total = if (totalPart == "*") null else totalPart.toLongOrNull()
    val range = spec.substring(0, slash).trim()
    if (range == "*") {
        return ContentRange(start = null, endInclusive = null, total = total)
    }
    val dash = range.indexOf('-')
    if (dash <= 0) {
        return null
    }
    val start = range.substring(0, dash).toLongOrNull() ?: return null
    val end = range.substring(dash + 1).toLongOrNull() ?: return null
    if (end < start) {
        return null
    }
    return ContentRange(start, end, total)
}

/** True when the server listed `bytes`, false when it listed only `none`, null when the header is absent. */
internal fun acceptsByteRanges(header: String?): Boolean? {
    if (header.isNullOrBlank()) {
        return null
    }
    val tokens = header.split(',').map { it.trim() }
    if (tokens.any { it.equals("bytes", ignoreCase = true) }) {
        return true
    }
    if (tokens.any { it.equals("none", ignoreCase = true) }) {
        return false
    }
    return null
}

internal fun normalizeEntityTag(header: String?): String? {
    if (header.isNullOrBlank()) {
        return null
    }
    val first = header.split(',').first().trim()
    if (first.isEmpty()) {
        return null
    }
    return first
}

internal fun entityTagsMatch(left: String, right: String): Boolean {
    return opaqueTag(left) == opaqueTag(right)
}

internal fun planPartialBody(
    status: Int,
    requestedOffset: Long,
    sentRange: Boolean,
    contentRange: ContentRange?,
    previousEtag: String?,
    responseEtag: String?,
): PartialBodyPlan {
    if (previousEtag != null && responseEtag != null && !entityTagsMatch(previousEtag, responseEtag)) {
        return PartialBodyPlan.RESTART
    }
    return when (status) {
        416 -> when {
            requestedOffset <= 0L -> PartialBodyPlan.REJECT
            contentRange?.total == null || contentRange.total == requestedOffset -> PartialBodyPlan.COMPLETE
            else -> PartialBodyPlan.RESTART
        }
        206 -> {
            val start = contentRange?.start
            if (start == null || start != requestedOffset) PartialBodyPlan.REJECT else PartialBodyPlan.APPEND
        }
        200 -> if (sentRange && requestedOffset > 0L) PartialBodyPlan.RESTART else PartialBodyPlan.APPEND
        else -> PartialBodyPlan.REJECT
    }
}

internal fun recoverFromConnectionLoss(
    bytesWrittenThisAttempt: Long,
    stop: DownloadOutcome?,
    message: String?,
): DownloadOutcome {
    if (stop != null) {
        return stop
    }
    if (bytesWrittenThisAttempt > 0L) {
        return DownloadOutcome.Yielded
    }
    return DownloadOutcome.Failed("io", message ?: "The connection was lost.", null, true)
}

internal fun endOfBody(
    cursor: Long,
    startOffset: Long,
    knownTotal: Long?,
    foreground: Boolean,
    rangeHonored: Boolean,
): DownloadOutcome {
    val took = cursor - startOffset
    val shortOfChunk = !foreground && rangeHonored && took < WorkVaultContract.chunkBytes
    val reachedTotal = knownTotal != null && cursor >= knownTotal
    val shortOfTotal = knownTotal != null && cursor < knownTotal
    return when {
        reachedTotal -> DownloadOutcome.Completed
        shortOfTotal && rangeHonored -> DownloadOutcome.Yielded
        shortOfTotal -> DownloadOutcome.Failed(
            "io",
            "The connection closed before the download finished.",
            null,
            true,
        )
        foreground || !rangeHonored || shortOfChunk -> DownloadOutcome.Completed
        else -> DownloadOutcome.Yielded
    }
}

private fun resolveTotal(connection: HttpURLConnection, code: Int, offset: Long): Long? {
    if (code == 206) {
        val remaining = connection.contentLengthLong.takeIf { it >= 0L } ?: return null
        return offset + remaining
    }
    return connection.contentLengthLong.takeIf { it >= 0L }
}

private fun opaqueTag(tag: String): String {
    val trimmed = tag.trim()
    val withoutWeak = if (trimmed.startsWith("W/", ignoreCase = true)) trimmed.substring(2).trim() else trimmed
    return withoutWeak
}
