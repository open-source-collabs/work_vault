package com.workvault.work_vault

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

internal data class TransferProgressUpdate(
    val bytes: Long,
    val totalBytes: Long?,
    val bytesPerSecond: Double,
    val elapsedMs: Long,
    val acceptsRanges: Boolean?,
    val etag: String?,
    val expectedSha256: String?,
    val expectedMd5: String?,
)

internal class TransferException(
    val code: String,
    override val message: String,
    val httpStatus: Int?,
    val retryable: Boolean,
) : IOException(message)

internal fun headerValue(headers: Map<String, String>, name: String): String? {
    return headers.entries
        .firstOrNull { it.key.equals(name, ignoreCase = true) }
        ?.value
        ?.trim()
        ?.ifEmpty { null }
}

/** Headers sent on the wire. Local checksum expectations stay on the device. */
internal fun wireHeaders(headers: Map<String, String>): Map<String, String> {
    return headers.filterKeys { name ->
        !name.equals(ChecksumVerifier.expectedSha256Header, ignoreCase = true) &&
            !name.equals(ChecksumVerifier.expectedMd5Header, ignoreCase = true)
    }
}

internal fun openHttps(
    taskId: String,
    initial: URL,
    method: String,
    headers: Map<String, String>,
    writeBody: ((HttpURLConnection) -> Unit)? = null,
    configure: HttpURLConnection.() -> Unit = {},
): HttpURLConnection {
    var url = initial
    var hops = 0
    while (hops <= WorkVaultContract.maxRedirects) {
        if (url.protocol != "https") {
            throw TransferException("http", "Redirect left https.", null, false)
        }
        val connection = (url.openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false
            connectTimeout = WorkVaultContract.connectTimeoutMs
            readTimeout = WorkVaultContract.readTimeoutMs
            requestMethod = method
            useCaches = false
            doInput = true
            if (headers.keys.none { it.equals("Accept-Encoding", ignoreCase = true) }) {
                setRequestProperty("Accept-Encoding", "identity")
            }
            if (headers.keys.none { it.equals("User-Agent", ignoreCase = true) }) {
                setRequestProperty("User-Agent", "work_vault")
            }
            for ((name, value) in headers) {
                setRequestProperty(name, value)
            }
            configure()
        }
        WorkVaultSignals.bind(taskId, connection)
        try {
            writeBody?.invoke(connection)
            val code = connection.responseCode
            if (code !in 300..399) {
                return connection
            }
            val location = connection.getHeaderField("Location")
            WorkVaultSignals.unbind(taskId, connection)
            connection.disconnect()
            if (location.isNullOrBlank()) {
                throw TransferException("redirect", "The server redirected without a location.", code, false)
            }
            hops += 1
            url = URL(url, location)
        } catch (error: TransferException) {
            WorkVaultSignals.unbind(taskId, connection)
            connection.disconnect()
            throw error
        } catch (error: IOException) {
            WorkVaultSignals.unbind(taskId, connection)
            connection.disconnect()
            throw error
        }
    }
    throw TransferException("redirect", "Too many redirects.", null, false)
}

internal fun httpFailure(code: Int): DownloadOutcome.Failed {
    val retryable = code == 408 || code == 429 || code >= 500
    return DownloadOutcome.Failed("http", "Transfer failed with HTTP $code.", code, retryable)
}
