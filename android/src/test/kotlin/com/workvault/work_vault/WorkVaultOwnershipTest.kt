package com.workvault.work_vault

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Version 1 ownership rules on the host side.
 *
 * The transfer surface is resumable HTTPS GET. TUS stays behind the method check. The
 * store is the authority for status, bytes, and the entity tag, and the projection it
 * sends to the headless isolate carries exactly that state.
 */
internal class WorkVaultOwnershipTest {
    @Test
    fun aGetTaskNeverRoutesToTheTusHandler() {
        assertEquals(TransferKind.RESUMABLE_GET, transferKind(ownedConfig()))
        assertEquals(
            TransferKind.RESUMABLE_GET,
            transferKind(ownedConfig(headers = mapOf("Tus-Resumable" to "1.0.0"))),
        )
        assertEquals(
            TransferKind.RESUMABLE_GET,
            transferKind(ownedConfig(headers = mapOf("Upload-Metadata" to "filename YQ=="))),
        )
    }

    @Test
    fun tusRunsOnlyForAnUploadVerbThatCarriesTheProtocolHeaders() {
        assertEquals(
            TransferKind.TUS_UPLOAD,
            transferKind(ownedConfig(method = HttpMethod.POST, headers = mapOf("Tus-Resumable" to "1.0.0"))),
        )
        assertEquals(
            TransferKind.TUS_UPLOAD,
            transferKind(ownedConfig(method = HttpMethod.PUT, headers = mapOf("Upload-Metadata" to "filename YQ=="))),
        )
        assertEquals(
            TransferKind.UNSUPPORTED,
            transferKind(ownedConfig(method = HttpMethod.POST)),
        )
        assertEquals(
            TransferKind.UNSUPPORTED,
            transferKind(ownedConfig(method = HttpMethod.PUT)),
        )
        assertEquals(
            TransferKind.UNSUPPORTED,
            transferKind(ownedConfig(method = HttpMethod.HEAD, headers = mapOf("Tus-Resumable" to "1.0.0"))),
        )
    }

    @Test
    fun theProjectionCarriesTheSameStateAsTheFlutterSnapshot() {
        val record = ownedRecord(
            status = TaskStatus.RUNNING,
            bytes = 64L,
            total = 128L,
            etag = "\"v1\"",
        )
        val projection = record.toProjection()
        val snapshot = record.toSnapshot()

        assertEquals(snapshot.taskId, projection["taskId"])
        assertEquals(snapshot.status.wireName(), projection["status"])
        assertEquals(snapshot.progress?.bytesDownloaded, projection["downloadedBytes"])
        assertEquals(snapshot.progress?.totalBytes, projection["totalBytes"])
        assertEquals(record.config.destinationPath, projection["filePath"])
        assertEquals("\"v1\"", projection["eTag"])
    }

    @Test
    fun theProjectionStatesEveryFieldSoAStaleRowIsCleared() {
        val keys = setOf("taskId", "status", "filePath", "downloadedBytes", "totalBytes", "eTag", "sha256")
        val unknown = ownedRecord(status = TaskStatus.ENQUEUED, bytes = 0L).toProjection()
        assertEquals(keys, unknown.keys)
        assertNull(unknown["totalBytes"])
        assertNull(unknown["eTag"])
        assertNull(unknown["sha256"])

        val known = ownedRecord(
            status = TaskStatus.COMPLETED,
            bytes = 3L,
            total = 3L,
            etag = "\"v2\"",
            sha256 = "ab".repeat(32),
        ).toProjection()
        assertEquals(keys, known.keys)
        assertEquals(3L, known["totalBytes"])
        assertEquals("\"v2\"", known["eTag"])
        assertEquals("ab".repeat(32), known["sha256"])
    }

    @Test
    fun theProjectionNormalizesCountsTheStoreCouldNotKnow() {
        val projection = ownedRecord(status = TaskStatus.ENQUEUED, bytes = -5L, total = -1L).toProjection()
        assertEquals(0L, projection["downloadedBytes"])
        assertNull(projection["totalBytes"])
    }

    @Test
    fun aBackgroundEventIsTheProjectionPlusItsKind() {
        val record = ownedRecord(status = TaskStatus.RUNNING, bytes = 10L, total = 20L)
        val projection = record.toProjection()
        for (kind in listOf("status", "progress")) {
            val event = record.toBackgroundEvent(kind)
            assertEquals(kind, event["kind"])
            assertEquals(projection, event.filterKeys { it != "kind" })
        }
    }

    @Test
    fun theStoreDecidesCompletedOrFailedForAChecksum() {
        val digests = FileDigests(sha256Hex = "ab".repeat(32), md5Hex = "cd".repeat(16))
        assertTrue(evaluateChecksum(digests, null, null) is ChecksumVerdict.Verified)
        assertTrue(evaluateChecksum(digests, digests.sha256Hex, digests.md5Hex) is ChecksumVerdict.Verified)
        val rejected = evaluateChecksum(digests, "ef".repeat(32), null)
        check(rejected is ChecksumVerdict.Rejected)
        assertEquals("checksum", rejected.failure.code)
        assertTrue(!rejected.failure.retryable)
    }

    @Test
    fun aCompletedRecordProjectsTheDigestTheStoreVerified() {
        val digest = "ab".repeat(32)
        val projection = ownedRecord(
            status = TaskStatus.COMPLETED,
            bytes = 3L,
            total = 3L,
            sha256 = digest,
        ).toProjection()
        assertEquals("completed", projection["status"])
        assertEquals(digest, projection["sha256"])
    }
}

private fun ownedConfig(
    method: HttpMethod = HttpMethod.GET,
    headers: Map<String, String> = emptyMap(),
): WorkTaskConfig {
    return WorkTaskConfig(
        taskId = "job-1",
        url = "https://cdn.example.com/archive.bin",
        destinationPath = "/data/user/0/com.workvault/files/archive.bin",
        method = method,
        headers = headers,
        network = NetworkConstraint.ANY,
        retry = RetryPolicy(3L, 1_000L, 300_000L, 2.0),
        battery = BatteryConstraint(false, false),
        notification = NotificationMetadata("Archive", "Saving", "downloads", "Downloads"),
    )
}

private fun ownedRecord(
    status: TaskStatus,
    bytes: Long,
    total: Long? = null,
    etag: String? = null,
    sha256: String? = null,
): TaskRecord {
    return TaskRecord(
        config = ownedConfig(),
        status = status,
        bytesDownloaded = bytes,
        totalBytes = total,
        bytesPerSecond = 0.0,
        elapsedMs = 0L,
        failure = null,
        attemptCount = 0,
        acceptsRanges = null,
        etag = etag,
        sha256 = sha256,
    )
}
