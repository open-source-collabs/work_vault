package com.workvault.work_vault

import java.io.File
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Protocol, retry, checksum, and Android version scenarios.
 *
 * The device floor is Android 8.0 (API 26). The dataSync quota starts at API 34.
 */
internal class WorkVaultProductionScenariosTest {
    @Test
    fun android8Through13DoesNotApplyTheDataSyncQuota() {
        for (sdk in 26..33) {
            assertFalse(dataSyncQuotaApplies(sdk), "API $sdk")
        }
    }

    @Test
    fun android14Through16AppliesTheDataSyncQuota() {
        for (sdk in 34..36) {
            assertTrue(dataSyncQuotaApplies(sdk), "API $sdk")
        }
    }

    @Test
    fun notificationIdsStayInsideTheSmallIntRange() {
        for (taskId in listOf("a", "job-1", "a".repeat(128), "archive:2026")) {
            val id = WorkVaultContract.notificationId(taskId)
            assertTrue(id in 40_000..72_767, taskId)
            assertEquals(id, WorkVaultContract.notificationId(taskId))
        }
    }

    @Test
    fun httpStatusClassifiesRetryableFailures() {
        val retryable = setOf(408, 429, 500, 502, 503, 504)
        val terminal = setOf(400, 401, 403, 404, 409, 410, 412, 422)
        for (code in retryable) {
            val failure = httpFailure(code)
            assertEquals("http", failure.code)
            assertTrue(failure.retryable, "HTTP $code")
            assertEquals(code, failure.httpStatus)
        }
        for (code in terminal) {
            assertFalse(httpFailure(code).retryable, "HTTP $code")
        }
    }

    @Test
    fun range416CompletesOnlyWhenTheLocalFileMatchesTheResourceLength() {
        assertEquals(
            PartialBodyPlan.COMPLETE,
            planPartialBody(416, 10L, true, null, null, null),
        )
        assertEquals(
            PartialBodyPlan.COMPLETE,
            planPartialBody(416, 100L, true, ContentRange(null, null, 100L), null, null),
        )
        assertEquals(
            PartialBodyPlan.RESTART,
            planPartialBody(416, 50L, true, ContentRange(null, null, 100L), null, null),
        )
        assertEquals(
            PartialBodyPlan.RESTART,
            planPartialBody(416, 80L, true, ContentRange(null, null, 40L), null, null),
        )
        assertEquals(
            PartialBodyPlan.REJECT,
            planPartialBody(416, 0L, true, ContentRange(null, null, 10L), null, null),
        )
    }

    @Test
    fun partialResponsesAppendRestartOrReject() {
        val match = ContentRange(100L, 199L, 400L)
        assertEquals(PartialBodyPlan.APPEND, planPartialBody(206, 100L, true, match, null, null))
        assertEquals(PartialBodyPlan.REJECT, planPartialBody(206, 100L, true, null, null, null))
        assertEquals(PartialBodyPlan.REJECT, planPartialBody(206, 100L, true, match.copy(start = 99L), null, null))
        assertEquals(PartialBodyPlan.RESTART, planPartialBody(200, 50L, true, null, null, null))
        assertEquals(PartialBodyPlan.APPEND, planPartialBody(200, 0L, false, null, null, null))
        assertEquals(PartialBodyPlan.RESTART, planPartialBody(206, 100L, true, match, "\"old\"", "\"new\""))
        assertEquals(PartialBodyPlan.APPEND, planPartialBody(206, 100L, true, match, "W/\"v1\"", "\"v1\""))
        assertEquals(PartialBodyPlan.REJECT, planPartialBody(201, 0L, false, null, null, null))
    }

    @Test
    fun contentRangeRejectsMalformedHeaders() {
        assertNull(parseContentRange(null))
        assertNull(parseContentRange(""))
        assertNull(parseContentRange("bytes"))
        assertNull(parseContentRange("items 0-1/2"))
        assertNull(parseContentRange("bytes 10-1/20"))
        assertNull(parseContentRange("bytes abc-def/20"))
        val open = parseContentRange("bytes 0-1023/*")
        assertEquals(0L, open?.start)
        assertEquals(1023L, open?.endInclusive)
        assertNull(open?.total)
        val unsatisfied = parseContentRange("bytes */4096")
        assertNull(unsatisfied?.start)
        assertEquals(4096L, unsatisfied?.total)
    }

    @Test
    fun acceptRangesAndEntityTags() {
        assertEquals(true, acceptsByteRanges("bytes"))
        assertEquals(true, acceptsByteRanges("Bytes"))
        assertEquals(true, acceptsByteRanges("none, bytes"))
        assertEquals(false, acceptsByteRanges("none"))
        assertEquals(false, acceptsByteRanges("NONE"))
        assertNull(acceptsByteRanges(null))
        assertNull(acceptsByteRanges(""))
        assertNull(acceptsByteRanges("items"))
        assertEquals("\"abc\"", normalizeEntityTag("\"abc\", \"def\""))
        assertNull(normalizeEntityTag("  "))
        assertTrue(entityTagsMatch("W/\"abc\"", "\"abc\""))
        assertTrue(entityTagsMatch("w/\"abc\"", "W/\"abc\""))
        assertFalse(entityTagsMatch("\"abc\"", "\"def\""))
    }

    @Test
    fun endOfBodyDecidesCompleteYieldOrRetry() {
        val chunk = WorkVaultContract.chunkBytes
        assertTrue(endOfBody(100L, 0L, 100L, false, true) is DownloadOutcome.Completed)
        assertTrue(endOfBody(50L, 0L, 100L, false, true) is DownloadOutcome.Yielded)
        val short = endOfBody(50L, 0L, 100L, false, false)
        check(short is DownloadOutcome.Failed)
        assertEquals("io", short.code)
        assertTrue(short.retryable)
        assertTrue(endOfBody(10L, 0L, null, true, true) is DownloadOutcome.Completed)
        assertTrue(endOfBody(100L, 0L, null, false, true) is DownloadOutcome.Completed)
        assertTrue(endOfBody(chunk, 0L, null, false, true) is DownloadOutcome.Yielded)
        assertTrue(endOfBody(chunk, 0L, null, false, false) is DownloadOutcome.Completed)
        assertTrue(endOfBody(0L, 0L, 0L, false, true) is DownloadOutcome.Completed)
    }

    @Test
    fun connectionLossKeepsBytesAndHonorsStop() {
        assertTrue(recoverFromConnectionLoss(1L, null, "reset") is DownloadOutcome.Yielded)
        assertTrue(recoverFromConnectionLoss(8L * 1024L * 1024L, null, null) is DownloadOutcome.Yielded)
        val failed = recoverFromConnectionLoss(0L, null, null)
        check(failed is DownloadOutcome.Failed)
        assertEquals("The connection was lost.", failed.message)
        assertTrue(failed.retryable)
        assertTrue(recoverFromConnectionLoss(32L, DownloadOutcome.Paused, "reset") is DownloadOutcome.Paused)
        assertTrue(recoverFromConnectionLoss(0L, DownloadOutcome.Cancelled, "reset") is DownloadOutcome.Cancelled)
    }

    @Test
    fun retryDelayFollowsTheScheduleAndTheCap() {
        val policy = RetryPolicy(5L, 1_000L, 10_000L, 2.0)
        assertEquals(1_000L, retryDelayMs(policy, 0))
        assertEquals(1_000L, retryDelayMs(policy, -1))
        assertEquals(2_000L, retryDelayMs(policy, 1))
        assertEquals(4_000L, retryDelayMs(policy, 2))
        assertEquals(8_000L, retryDelayMs(policy, 3))
        assertEquals(10_000L, retryDelayMs(policy, 4))
        assertEquals(10_000L, retryDelayMs(policy, 20))
        val flat = RetryPolicy(3L, 500L, 500L, 8.0)
        assertEquals(500L, retryDelayMs(flat, 0))
        assertEquals(500L, retryDelayMs(flat, 1))
        val huge = RetryPolicy(4L, 1_000L, 60_000L, 1_000_000.0)
        assertEquals(60_000L, retryDelayMs(huge, 2))
    }

    @Test
    fun percentageClampsAndHidesAnUnknownLength() {
        assertNull(percentageOf(10L, null))
        assertNull(percentageOf(10L, 0L))
        assertNull(percentageOf(10L, -1L))
        assertEquals(0.0, percentageOf(0L, 100L))
        assertEquals(50.0, percentageOf(50L, 100L))
        assertEquals(100.0, percentageOf(150L, 100L))
        assertEquals(0.0, percentageOf(-5L, 100L))
    }

    @Test
    fun dataSyncBudgetAccountsForTheRollingWindow() {
        val hour = 60L * 60L * 1000L
        val now = 48 * hour
        assertEquals(0L, dataSyncUsedMs(now, emptyList(), windowMs = 24 * hour))
        assertEquals(0L, dataSyncUsedMs(now, listOf(BudgetSession(0L, hour)), windowMs = 24 * hour))
        val recent = listOf(BudgetSession(now - 2 * hour, now - hour))
        assertEquals(hour, dataSyncUsedMs(now, recent, windowMs = 24 * hour))
        assertTrue(canStartDataSync(now, recent, quotaMs = 6 * hour, windowMs = 24 * hour, marginMs = 60_000L))
        assertFalse(
            shouldYieldDataSync(
                nowMs = now,
                sessionStartMs = now,
                closedSessions = recent,
                quotaMs = 6 * hour,
                windowMs = 24 * hour,
                marginMs = 60_000L,
            ),
        )
        assertTrue(
            shouldYieldDataSync(
                nowMs = now,
                sessionStartMs = now - (5 * hour),
                closedSessions = recent,
                quotaMs = 6 * hour,
                windowMs = 24 * hour,
                marginMs = 60_000L,
            ),
        )
    }

    @Test
    fun checksumHeadersStayOffTheWireAndDigestsNormalize() {
        val sha = "ab".repeat(32)
        val md5 = "cd".repeat(16)
        val wire = wireHeaders(
            mapOf(
                "Authorization" to "Bearer token",
                "x-work-vault-sha256" to sha,
                "X-Work-Vault-Md5" to md5,
            ),
        )
        assertEquals(mapOf("Authorization" to "Bearer token"), wire)
        assertEquals(sha, normalizeHexDigest(sha.uppercase(), 32))
        assertEquals(md5, normalizeHexDigest("  $md5  ", 16))
        assertNull(normalizeHexDigest(sha.dropLast(1), 32))
        assertNull(normalizeHexDigest("zz".repeat(32), 32))
        assertNull(normalizeHexDigest(null, 32))
        assertEquals(sha, headerValue(mapOf("X-Work-Vault-Sha256" to " $sha "), "x-work-vault-sha256"))
        assertNull(headerValue(mapOf("X-Work-Vault-Sha256" to "   "), "X-Work-Vault-Sha256"))
    }

    @Test
    fun fileDigestsMatchKnownVectorsAndRejectAMismatch() {
        val empty = File.createTempFile("work-vault-empty", ".bin")
        val sample = File.createTempFile("work-vault-abc", ".bin")
        val binary = File.createTempFile("work-vault-bin", ".bin")
        try {
            sample.writeBytes("abc".toByteArray())
            binary.writeBytes(byteArrayOf(0, -1, 16))
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
            val verified = evaluateChecksum(sampleDigests, sampleDigests.sha256Hex.uppercase(), sampleDigests.md5Hex)
            assertTrue(verified is ChecksumVerdict.Verified)
            val shaMismatch = evaluateChecksum(sampleDigests, emptyDigests.sha256Hex, null) as ChecksumVerdict.Rejected
            assertEquals("checksum", shaMismatch.failure.code)
            assertFalse(shaMismatch.failure.retryable)
            val md5Mismatch = evaluateChecksum(sampleDigests, null, emptyDigests.md5Hex) as ChecksumVerdict.Rejected
            assertEquals("checksum", md5Mismatch.failure.code)
            assertTrue(digestFile(binary).sha256Hex.length == 64)
        } finally {
            empty.delete()
            sample.delete()
            binary.delete()
        }
    }

    @Test
    fun resumedBytesAppendBeforeTheDigestIsChecked() {
        val file = File.createTempFile("work-vault-resume", ".bin")
        try {
            file.writeBytes("ab".toByteArray())
            file.appendBytes("c".toByteArray())
            val digests = digestFile(file)
            assertEquals(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                digests.sha256Hex,
            )
            val expected = MessageDigest.getInstance("MD5").digest("abc".toByteArray()).toHex()
            assertEquals(expected, digests.md5Hex)
        } finally {
            file.delete()
        }
    }

    @Test
    fun configValidationCoversUrlsPathsMethodsAndRetry() {
        assertNull(validateConfig(scenarioConfig()))
        assertEquals(
            "url must be an absolute https URL.",
            validateConfig(scenarioConfig(url = "http://example.com/file.bin")),
        )
        assertEquals(
            "url must be an absolute https URL.",
            validateConfig(scenarioConfig(url = "https://")),
        )
        assertEquals(
            "destinationPath must be an absolute file path.",
            validateConfig(scenarioConfig(destinationPath = "archive.bin")),
        )
        assertNull(validateConfig(scenarioConfig(destinationPath = "D:\\Downloads\\archive.bin")))
        assertEquals(
            "Only GET downloads are supported in this version.",
            validateConfig(scenarioConfig(method = HttpMethod.POST)),
        )
        assertNull(
            validateConfig(
                scenarioConfig(
                    method = HttpMethod.POST,
                    headers = mapOf("Tus-Resumable" to "1.0.0"),
                ),
            ),
        )
        assertEquals(
            "taskId must contain 1 to 128 letters, digits, dots, underscores, hyphens, or colons.",
            validateConfig(scenarioConfig(taskId = "../escape")),
        )
        assertEquals(
            "retry.maxAttempts must be at least 1.",
            validateConfig(scenarioConfig(retry = RetryPolicy(0L, 1_000L, 5_000L, 2.0))),
        )
        assertEquals(
            "retry.multiplier must be a finite number >= 1.",
            validateConfig(scenarioConfig(retry = RetryPolicy(3L, 1_000L, 5_000L, Double.NaN))),
        )
        assertEquals(
            "notification.title must be visible text without control characters.",
            validateConfig(
                scenarioConfig(
                    notification = NotificationMetadata("  ", "Body", "downloads", "Downloads"),
                ),
            ),
        )
    }

    @Test
    fun statusNamesRoundTripAndTerminalStatesStayTerminal() {
        for (status in TaskStatus.entries) {
            assertEquals(status, taskStatusFromWire(status.wireName()))
            assertEquals(status.isTerminal(), status == TaskStatus.COMPLETED || status == TaskStatus.FAILED || status == TaskStatus.CANCELLED)
        }
        assertNull(taskStatusFromWire("paused "))
        assertNull(taskStatusFromWire("unknown"))
        assertEquals("pause", TaskCommand.PAUSE.wireName())
        assertEquals("resume", TaskCommand.RESUME.wireName())
        assertEquals("cancel", TaskCommand.CANCEL.wireName())
    }

    @Test
    fun transitionsMatchEveryStatusAndCommand() {
        val legal = mapOf(
            (TaskStatus.RUNNING to TaskCommand.PAUSE) to TaskStatus.PAUSED,
            (TaskStatus.PAUSED to TaskCommand.RESUME) to TaskStatus.RUNNING,
            (TaskStatus.ENQUEUED to TaskCommand.CANCEL) to TaskStatus.CANCELLED,
            (TaskStatus.RUNNING to TaskCommand.CANCEL) to TaskStatus.CANCELLED,
            (TaskStatus.PAUSED to TaskCommand.CANCEL) to TaskStatus.CANCELLED,
        )
        for (status in TaskStatus.entries) {
            for (command in TaskCommand.entries) {
                assertEquals(legal[status to command], nextTaskStatus(status, command), "${status.wireName()} ${command.wireName()}")
            }
        }
    }

    @Test
    fun tusMetadataAndChecksumFraming() {
        assertEquals("report.bin", parseTusMetadata(encodeTusMetadata(mapOf("filename" to "report.bin")))["filename"])
        assertEquals("", parseTusMetadata("filename !!!")["filename"])
        assertEquals("", parseTusMetadata("bare")["bare"])
        assertEquals(setOf("creation", "checksum"), parseListHeader("Creation, checksum"))
        assertEquals(emptySet(), parseListHeader(null))
        assertEquals(emptySet(), parseListHeader(" , "))
        assertEquals(0L, parseUploadOffset("0"))
        assertEquals(128L, parseUploadOffset(" 128 "))
        assertNull(parseUploadOffset("-1"))
        assertNull(parseUploadOffset("nope"))
        assertNull(sha256HexFromDigestHeader(null))
        assertNull(sha256HexFromDigestHeader("md5=:abc=:"))
        assertNull(md5HexFromContentMd5("%%%"))
        assertNull(md5HexFromContentMd5(null))
        val digest = MessageDigest.getInstance("SHA-256").digest("abc".toByteArray())
        assertEquals(digest.toHex(), sha256HexFromDigestHeader("sha-256=:${headerBase64(digest)}:"))
        val md5 = MessageDigest.getInstance("MD5").digest(ByteArray(0))
        assertEquals(md5.toHex(), md5HexFromContentMd5(headerBase64(md5)))
    }

    @Test
    fun contentRangeTotalAndWorkNames() {
        assertEquals(4096L, contentRangeTotal("bytes 0-1023/4096"))
        assertNull(contentRangeTotal("bytes 0-1023/*"))
        assertNull(contentRangeTotal("bytes 0-1023/"))
        assertNull(contentRangeTotal(null))
        assertEquals("work_vault:job-1", WorkVaultContract.uniqueWorkName("job-1"))
        assertEquals("work_vault:periodic:job-1", WorkVaultContract.periodicWorkName("job-1"))
        assertEquals(8L * 1024L * 1024L, WorkVaultContract.chunkBytes)
        assertEquals(5, WorkVaultContract.maxRedirects)
    }

    private fun headerBase64(raw: ByteArray): String =
        java.util.Base64.getEncoder().encodeToString(raw)
}

private fun scenarioConfig(
    taskId: String = "task-1",
    url: String = "https://example.com/file.bin",
    destinationPath: String = "/data/user/0/com.workvault/files/file.bin",
    method: HttpMethod = HttpMethod.GET,
    headers: Map<String, String> = mapOf("Accept" to "application/octet-stream"),
    retry: RetryPolicy = RetryPolicy(3L, 1_000L, 300_000L, 2.0),
    notification: NotificationMetadata = NotificationMetadata("Title", "Body", "downloads", "Downloads"),
): WorkTaskConfig {
    return WorkTaskConfig(
        taskId = taskId,
        url = url,
        destinationPath = destinationPath,
        method = method,
        headers = headers,
        network = NetworkConstraint.ANY,
        retry = retry,
        battery = BatteryConstraint(false, false),
        notification = notification,
    )
}
