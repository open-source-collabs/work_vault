package com.workvault.work_vault

import java.io.File
import java.security.MessageDigest
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class WorkVaultTransferTest {
    @Test
    fun contentRangeParsesPartialAndUnsatisfiedForms() {
        val partial = parseContentRange("bytes 1024-2047/4096")
        assertEquals(1024L, partial?.start)
        assertEquals(2047L, partial?.endInclusive)
        assertEquals(4096L, partial?.total)
        val unknown = parseContentRange("bytes */8192")
        assertNull(unknown?.start)
        assertEquals(8192L, unknown?.total)
        assertNull(parseContentRange("bytes 0-1023/*")?.total)
        assertNull(parseContentRange(null))
    }

    @Test
    fun acceptRangesDistinguishesBytesNoneAndAbsence() {
        assertEquals(true, acceptsByteRanges("bytes"))
        assertEquals(true, acceptsByteRanges("none, bytes"))
        assertEquals(false, acceptsByteRanges("none"))
        assertNull(acceptsByteRanges(null))
        assertNull(acceptsByteRanges("items"))
    }

    @Test
    fun weakValidatorsMatchTheSameOpaqueTag() {
        assertTrue(entityTagsMatch("W/\"abc\"", "\"abc\""))
        assertFalse(entityTagsMatch("\"abc\"", "\"def\""))
    }

    @Test
    fun partialBodyPlanAppendsOnlyAMatching206() {
        val match = ContentRange(start = 100L, endInclusive = 199L, total = 400L)
        assertEquals(
            PartialBodyPlan.APPEND,
            planPartialBody(206, 100L, true, match, "\"v1\"", "\"v1\""),
        )
        assertEquals(
            PartialBodyPlan.REJECT,
            planPartialBody(206, 100L, true, match.copy(start = 0L), null, null),
        )
        assertEquals(
            PartialBodyPlan.RESTART,
            planPartialBody(200, 50L, true, null, null, null),
        )
        assertEquals(
            PartialBodyPlan.APPEND,
            planPartialBody(200, 0L, false, null, null, null),
        )
        assertEquals(
            PartialBodyPlan.COMPLETE,
            planPartialBody(416, 10L, true, null, null, null),
        )
        assertEquals(
            PartialBodyPlan.REJECT,
            planPartialBody(416, 0L, true, null, null, null),
        )
        assertEquals(
            PartialBodyPlan.RESTART,
            planPartialBody(206, 100L, true, match, "\"old\"", "\"new\""),
        )
    }

    @Test
    fun connectionLossKeepsBytesAlreadyWritten() {
        assertTrue(recoverFromConnectionLoss(64L, null, "reset") is DownloadOutcome.Yielded)
        val failed = recoverFromConnectionLoss(0L, null, "reset")
        assertTrue(failed is DownloadOutcome.Failed)
        assertEquals("io", failed.code)
        assertTrue(recoverFromConnectionLoss(64L, DownloadOutcome.Paused, "reset") is DownloadOutcome.Paused)
    }

    @Test
    fun tusMetadataAndChecksumFramingRoundTrip() {
        val encoded = encodeTusMetadata(mapOf("filename" to "report.bin"))
        assertEquals("report.bin", parseTusMetadata(encoded)["filename"])
        assertEquals(setOf("creation", "checksum"), parseListHeader("creation, checksum"))
        assertEquals(128L, parseUploadOffset("128"))
        assertNull(parseUploadOffset("-1"))

        val digest = MessageDigest.getInstance("SHA-256").digest("abc".toByteArray())
        val header = uploadChecksumHeader("sha256", digest)
        assertEquals("sha256 ${Base64.getEncoder().encodeToString(digest)}", header)
        assertEquals(digest.toHex(), sha256HexFromDigestHeader("sha-256=:${headerBase64(digest)}:"))
        assertEquals(digest.toHex(), sha256HexFromDigestHeader("sha-256=${headerBase64(digest)}"))
        val md5 = MessageDigest.getInstance("MD5").digest(ByteArray(0))
        assertEquals(md5.toHex(), md5HexFromContentMd5(headerBase64(md5)))
    }

    @Test
    fun tusUploadsAreLimitedToPostOrPutWithProtocolHeaders() {
        assertTrue(isTusUpload(transferConfig(HttpMethod.POST, mapOf("Tus-Resumable" to "1.0.0"))))
        assertTrue(isTusUpload(transferConfig(HttpMethod.PUT, mapOf("Upload-Metadata" to "filename YQ=="))))
        assertFalse(isTusUpload(transferConfig(HttpMethod.POST, emptyMap())))
        assertFalse(isTusUpload(transferConfig(HttpMethod.GET, mapOf("Tus-Resumable" to "1.0.0"))))
        assertNull(validateConfig(transferConfig(HttpMethod.POST, mapOf("Tus-Resumable" to "1.0.0"))))
        assertEquals(
            "Only GET downloads are supported in this version.",
            validateConfig(transferConfig(HttpMethod.POST, emptyMap())),
        )
    }

    @Test
    fun localChecksumHeadersStayOffTheWire() {
        val wire = wireHeaders(
            mapOf(
                "Authorization" to "Bearer token",
                "X-Work-Vault-Sha256" to "ab".repeat(32),
                "X-Work-Vault-Md5" to "cd".repeat(16),
            ),
        )
        assertEquals(mapOf("Authorization" to "Bearer token"), wire)
    }

    @Test
    fun diskBufferHashMatchesKnownVectorsBeforeCompletion() {
        val empty = File.createTempFile("work-vault-empty", ".bin")
        val sample = File.createTempFile("work-vault-abc", ".bin")
        try {
            sample.writeBytes("abc".toByteArray())
            val emptyDigests = digestFile(empty)
            assertEquals(
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                emptyDigests.sha256Hex,
            )
            assertEquals("d41d8cd98f00b204e9800998ecf8427e", emptyDigests.md5Hex)
            val sampleDigests = digestFile(sample)
            assertEquals(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                sampleDigests.sha256Hex,
            )
            assertEquals("900150983cd24fb0d6963f7d28e17f72", sampleDigests.md5Hex)
            val mismatch = evaluateChecksum(sampleDigests, emptyDigests.sha256Hex, null)
            val rejected = mismatch as ChecksumVerdict.Rejected
            assertFalse(rejected.failure.retryable)
            assertEquals("checksum", rejected.failure.code)
            val match = evaluateChecksum(sampleDigests, sampleDigests.sha256Hex.uppercase(), sampleDigests.md5Hex)
            assertTrue(match is ChecksumVerdict.Verified)
        } finally {
            empty.delete()
            sample.delete()
        }
    }

    private fun headerBase64(raw: ByteArray): String = Base64.getEncoder().encodeToString(raw)
}

private fun transferConfig(method: HttpMethod, headers: Map<String, String>): WorkTaskConfig {
    return WorkTaskConfig(
        taskId = "task-1",
        url = "https://example.com/files",
        destinationPath = "/data/user/0/com.workvault/files/file.bin",
        method = method,
        headers = headers,
        network = NetworkConstraint.ANY,
        retry = RetryPolicy(3L, 1_000L, 300_000L, 2.0),
        battery = BatteryConstraint(false, false),
        notification = NotificationMetadata("Title", "Body", "downloads", "Downloads"),
    )
}
