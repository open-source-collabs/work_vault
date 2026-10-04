package com.workvault.work_vault

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class WorkVaultPluginTest {
    @Test
    fun transitionsMatchTheDartStateMachine() {
        val table = listOf<Triple<TaskStatus, TaskCommand, TaskStatus?>>(
            Triple(TaskStatus.ENQUEUED, TaskCommand.PAUSE, null),
            Triple(TaskStatus.ENQUEUED, TaskCommand.RESUME, null),
            Triple(TaskStatus.ENQUEUED, TaskCommand.CANCEL, TaskStatus.CANCELLED),
            Triple(TaskStatus.RUNNING, TaskCommand.PAUSE, TaskStatus.PAUSED),
            Triple(TaskStatus.RUNNING, TaskCommand.RESUME, null),
            Triple(TaskStatus.RUNNING, TaskCommand.CANCEL, TaskStatus.CANCELLED),
            Triple(TaskStatus.PAUSED, TaskCommand.PAUSE, null),
            Triple(TaskStatus.PAUSED, TaskCommand.RESUME, TaskStatus.RUNNING),
            Triple(TaskStatus.PAUSED, TaskCommand.CANCEL, TaskStatus.CANCELLED),
            Triple(TaskStatus.COMPLETED, TaskCommand.PAUSE, null),
            Triple(TaskStatus.COMPLETED, TaskCommand.RESUME, null),
            Triple(TaskStatus.COMPLETED, TaskCommand.CANCEL, null),
            Triple(TaskStatus.FAILED, TaskCommand.PAUSE, null),
            Triple(TaskStatus.FAILED, TaskCommand.RESUME, null),
            Triple(TaskStatus.FAILED, TaskCommand.CANCEL, null),
            Triple(TaskStatus.CANCELLED, TaskCommand.PAUSE, null),
            Triple(TaskStatus.CANCELLED, TaskCommand.RESUME, null),
            Triple(TaskStatus.CANCELLED, TaskCommand.CANCEL, null),
        )
        for ((from, command, expected) in table) {
            assertEquals(expected, nextTaskStatus(from, command), "${from.wireName()} ${command.wireName()}")
        }
    }

    @Test
    fun dataSyncBudgetYieldsBeforeTheSixHourCap() {
        val hour = 60L * 60L * 1000L
        val now = 48 * hour
        val sessions = listOf(BudgetSession(startMs = now - 5 * hour, endMs = now - hour))
        assertEquals(4 * hour, dataSyncUsedMs(now, sessions, windowMs = 24 * hour))
        assertTrue(canStartDataSync(now, sessions, quotaMs = 6 * hour, windowMs = 24 * hour, marginMs = 60_000L))
        assertFalse(
            canStartDataSync(
                now,
                sessions + BudgetSession(now - 3 * hour, now - hour),
                quotaMs = 6 * hour,
                windowMs = 24 * hour,
                marginMs = 60_000L,
            ),
        )
        assertTrue(
            shouldYieldDataSync(
                nowMs = now,
                sessionStartMs = now - (2 * hour),
                closedSessions = sessions,
                quotaMs = 6 * hour,
                windowMs = 24 * hour,
                marginMs = 60_000L,
            ),
        )
        assertEquals(0L, dataSyncUsedMs(now, listOf(BudgetSession(0L, hour)), windowMs = 24 * hour))
    }

    @Test
    fun retryDelayHonorsMultiplierAndCap() {
        val policy = RetryPolicy(
            maxAttempts = 5L,
            initialBackoffMs = 1_000L,
            maxBackoffMs = 10_000L,
            multiplier = 2.0,
        )
        assertEquals(1_000L, retryDelayMs(policy, 0))
        assertEquals(2_000L, retryDelayMs(policy, 1))
        assertEquals(4_000L, retryDelayMs(policy, 2))
        assertEquals(8_000L, retryDelayMs(policy, 3))
        assertEquals(10_000L, retryDelayMs(policy, 4))
    }

    @Test
    fun contentRangeTotalIgnoresUnknownSizes() {
        assertEquals(4096L, contentRangeTotal("bytes 0-1023/4096"))
        assertNull(contentRangeTotal("bytes 0-1023/*"))
        assertNull(contentRangeTotal(null))
    }

    @Test
    fun validateConfigRejectsNonHttpsAndNonGet() {
        assertNull(validateConfig(sampleConfig()))
        assertEquals(
            "url must be an absolute https URL.",
            validateConfig(sampleConfig(url = "http://example.com/file")),
        )
        assertEquals(
            "Only GET downloads are supported in this version.",
            validateConfig(sampleConfig(method = HttpMethod.POST)),
        )
    }

    @Test
    fun quotaGateStartsAtAndroid14() {
        assertFalse(dataSyncQuotaApplies(33))
        assertTrue(dataSyncQuotaApplies(34))
        assertTrue(dataSyncQuotaApplies(35))
    }
}

private fun sampleConfig(
    url: String = "https://example.com/file.bin",
    method: HttpMethod = HttpMethod.GET,
): WorkTaskConfig {
    return WorkTaskConfig(
        taskId = "task-1",
        url = url,
        destinationPath = "/data/user/0/com.workvault/files/file.bin",
        method = method,
        headers = mapOf("Accept" to "application/octet-stream"),
        network = NetworkConstraint.ANY,
        retry = RetryPolicy(3L, 1_000L, 300_000L, 2.0),
        battery = BatteryConstraint(false, false),
        notification = NotificationMetadata("Title", "Body", "downloads", "Downloads"),
    )
}
