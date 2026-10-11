package com.workvault.work_vault

import android.os.Process
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * SHA-256 and MD5 of a completed file, read from a direct disk buffer.
 *
 * Hashing runs at background thread priority and finishes before a task is marked complete.
 */
internal object ChecksumVerifier {
    const val expectedSha256Header = "X-Work-Vault-Sha256"
    const val expectedMd5Header = "X-Work-Vault-Md5"

    private val dispatcher = Dispatchers.IO.limitedParallelism(1)

    suspend fun verify(file: File, expectedSha256: String?, expectedMd5: String?): ChecksumVerdict {
        return withContext(dispatcher) {
            val previous = currentPriority()
            setBackgroundPriority()
            try {
                if (!file.isFile) {
                    return@withContext ChecksumVerdict.Rejected(
                        DownloadOutcome.Failed("io", "The completed file is missing.", null, true),
                    )
                }
                val digests = try {
                    digestFile(file)
                } catch (error: Exception) {
                    return@withContext ChecksumVerdict.Rejected(
                        DownloadOutcome.Failed("io", error.message ?: "The file could not be hashed.", null, true),
                    )
                }
                evaluateChecksum(digests, expectedSha256, expectedMd5)
            } finally {
                restorePriority(previous)
            }
        }
    }
}

internal sealed class ChecksumVerdict {
    data class Verified(val sha256: String, val md5: String) : ChecksumVerdict()

    data class Rejected(val failure: DownloadOutcome.Failed) : ChecksumVerdict()
}

internal data class FileDigests(val sha256Hex: String, val md5Hex: String)

/** One sequential read of [file]. Both digests are updated from the same direct buffer. */
internal fun digestFile(file: File): FileDigests {
    val sha256 = MessageDigest.getInstance("SHA-256")
    val md5 = MessageDigest.getInstance("MD5")
    FileInputStream(file).channel.use { channel ->
        val buffer = ByteBuffer.allocateDirect(256 * 1024)
        while (true) {
            buffer.clear()
            val read = channel.read(buffer)
            if (read < 0) {
                break
            }
            if (read == 0) {
                continue
            }
            buffer.flip()
            val md5View = buffer.duplicate()
            sha256.update(buffer)
            md5.update(md5View)
        }
    }
    return FileDigests(sha256Hex = sha256.digest().toHex(), md5Hex = md5.digest().toHex())
}

internal fun evaluateChecksum(
    digests: FileDigests,
    expectedSha256: String?,
    expectedMd5: String?,
): ChecksumVerdict {
    val sha = normalizeHexDigest(expectedSha256, 32)
    val md5 = normalizeHexDigest(expectedMd5, 16)
    if (sha != null && sha != digests.sha256Hex) {
        return ChecksumVerdict.Rejected(
            DownloadOutcome.Failed(
                "checksum",
                "SHA-256 of the file does not match the expected digest.",
                null,
                false,
            ),
        )
    }
    if (md5 != null && md5 != digests.md5Hex) {
        return ChecksumVerdict.Rejected(
            DownloadOutcome.Failed(
                "checksum",
                "MD5 of the file does not match the expected digest.",
                null,
                false,
            ),
        )
    }
    return ChecksumVerdict.Verified(sha256 = digests.sha256Hex, md5 = digests.md5Hex)
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

/**
 * Picks the digest a completed file is checked against.
 *
 * A digest the caller supplied always wins, so a server cannot vouch for its own bytes. A server
 * digest is used only when the caller supplied none, and [previous] carries an earlier value
 * across retries and process restarts.
 */
internal fun resolveExpectedDigest(callerSupplied: String?, fromServer: String?, previous: String?): String? =
    callerSupplied ?: fromServer ?: previous

internal fun ByteArray.toHex(): String {
    val chars = CharArray(size * 2)
    val alphabet = "0123456789abcdef"
    for (index in indices) {
        val value = this[index].toInt() and 0xff
        chars[index * 2] = alphabet[value ushr 4]
        chars[index * 2 + 1] = alphabet[value and 0x0f]
    }
    return String(chars)
}

private fun currentPriority(): Int? {
    return try {
        Process.getThreadPriority(Process.myTid())
    } catch (_: Throwable) {
        null
    }
}

private fun setBackgroundPriority() {
    try {
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
    } catch (_: Throwable) {
        // Hosts without an Android process scheduler still hash the file.
    }
}

private fun restorePriority(previous: Int?) {
    if (previous == null) {
        return
    }
    try {
        Process.setThreadPriority(previous)
    } catch (_: Throwable) {
        // Restoring priority is best-effort on hosts without a process scheduler.
    }
}
