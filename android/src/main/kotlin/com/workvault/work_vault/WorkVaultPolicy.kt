package com.workvault.work_vault

import java.net.URI
import java.util.Locale

internal object WorkVaultContract {
    const val tag = "WorkVault"
    const val keyTaskId = "taskId"
    const val keyMode = "mode"
    const val modeForeground = "foreground"
    const val modeChunk = "chunk"
    const val modePeriodic = "periodic"
    const val workTag = "work_vault"
    const val chunkBudgetMs = 8L * 60L * 1000L
    const val chunkBytes = 8L * 1024L * 1024L
    const val readBufferBytes = 64 * 1024
    const val syncEveryBytes = 1024 * 1024
    const val progressIntervalMs = 250L
    const val dataSyncQuotaMs = 6L * 60L * 60L * 1000L
    const val dataSyncWindowMs = 24L * 60L * 60L * 1000L
    const val dataSyncYieldMarginMs = 60L * 1000L
    const val periodicMinutes = 15L
    const val maxRedirects = 5
    const val connectTimeoutMs = 20_000
    const val readTimeoutMs = 20_000
    const val permissionRequestCode = 0x5756

    fun uniqueWorkName(taskId: String): String = "work_vault:$taskId"

    fun periodicWorkName(taskId: String): String = "work_vault:periodic:$taskId"

    fun notificationId(taskId: String): Int = 40_000 + (taskId.hashCode() ushr 16 and 0x7FFF)
}

internal enum class TaskCommand {
    PAUSE,
    RESUME,
    CANCEL,
}

/** Execution path chosen for a stored task. Version 1 runs resumable HTTPS GET only. */
internal enum class TransferKind {
    RESUMABLE_GET,
    TUS_UPLOAD,
    UNSUPPORTED,
}

/**
 * Routes a stored config to the engine that may run it.
 *
 * The method check is the only gate: a GET never reaches the TUS handler, and a verb the
 * download engine cannot resume never reaches [ResumableEngine].
 */
internal fun transferKind(config: WorkTaskConfig): TransferKind = when {
    isTusUpload(config) -> TransferKind.TUS_UPLOAD
    config.method == HttpMethod.GET -> TransferKind.RESUMABLE_GET
    else -> TransferKind.UNSUPPORTED
}

/** Android 14 introduces the typed dataSync service. Android 15 enforces the 6-hour cap. */
internal fun dataSyncQuotaApplies(sdkInt: Int): Boolean = sdkInt >= 34

internal data class BudgetSession(val startMs: Long, val endMs: Long)

internal fun dataSyncUsedMs(
    nowMs: Long,
    sessions: List<BudgetSession>,
    windowMs: Long = WorkVaultContract.dataSyncWindowMs,
): Long {
    val windowStart = nowMs - windowMs
    var used = 0L
    for (session in sessions) {
        val start = maxOf(session.startMs, windowStart)
        val end = minOf(session.endMs, nowMs)
        if (end > start) {
            used += end - start
        }
    }
    return used
}

internal fun dataSyncRemainingMs(
    nowMs: Long,
    sessions: List<BudgetSession>,
    quotaMs: Long = WorkVaultContract.dataSyncQuotaMs,
    windowMs: Long = WorkVaultContract.dataSyncWindowMs,
): Long = (quotaMs - dataSyncUsedMs(nowMs, sessions, windowMs)).coerceAtLeast(0L)

internal fun canStartDataSync(
    nowMs: Long,
    sessions: List<BudgetSession>,
    quotaMs: Long = WorkVaultContract.dataSyncQuotaMs,
    windowMs: Long = WorkVaultContract.dataSyncWindowMs,
    marginMs: Long = WorkVaultContract.dataSyncYieldMarginMs,
): Boolean = dataSyncRemainingMs(nowMs, sessions, quotaMs, windowMs) > marginMs

internal fun shouldYieldDataSync(
    nowMs: Long,
    sessionStartMs: Long,
    closedSessions: List<BudgetSession>,
    quotaMs: Long = WorkVaultContract.dataSyncQuotaMs,
    windowMs: Long = WorkVaultContract.dataSyncWindowMs,
    marginMs: Long = WorkVaultContract.dataSyncYieldMarginMs,
): Boolean {
    val openMs = (nowMs - sessionStartMs).coerceAtLeast(0L)
    val used = dataSyncUsedMs(nowMs, closedSessions, windowMs)
    return used + openMs >= quotaMs - marginMs
}

internal fun TaskStatus.isTerminal(): Boolean = when (this) {
    TaskStatus.COMPLETED, TaskStatus.FAILED, TaskStatus.CANCELLED -> true
    TaskStatus.ENQUEUED, TaskStatus.RUNNING, TaskStatus.PAUSED -> false
}

internal fun TaskStatus.wireName(): String = name.lowercase(Locale.US)

internal fun TaskCommand.wireName(): String = name.lowercase(Locale.US)

internal fun taskStatusFromWire(name: String): TaskStatus? = when (name) {
    "enqueued" -> TaskStatus.ENQUEUED
    "running" -> TaskStatus.RUNNING
    "paused" -> TaskStatus.PAUSED
    "completed" -> TaskStatus.COMPLETED
    "failed" -> TaskStatus.FAILED
    "cancelled" -> TaskStatus.CANCELLED
    else -> null
}

internal fun nextTaskStatus(from: TaskStatus, command: TaskCommand): TaskStatus? = when (from to command) {
    TaskStatus.ENQUEUED to TaskCommand.CANCEL -> TaskStatus.CANCELLED
    TaskStatus.RUNNING to TaskCommand.PAUSE -> TaskStatus.PAUSED
    TaskStatus.RUNNING to TaskCommand.CANCEL -> TaskStatus.CANCELLED
    TaskStatus.PAUSED to TaskCommand.RESUME -> TaskStatus.RUNNING
    TaskStatus.PAUSED to TaskCommand.CANCEL -> TaskStatus.CANCELLED
    else -> null
}

internal fun percentageOf(bytes: Long, total: Long?): Double? {
    if (total == null || total <= 0L) {
        return null
    }
    return (bytes.toDouble() * 100.0 / total.toDouble()).coerceIn(0.0, 100.0)
}

internal fun contentRangeTotal(header: String?): Long? {
    if (header.isNullOrBlank()) {
        return null
    }
    val slash = header.lastIndexOf('/')
    if (slash < 0 || slash == header.lastIndex) {
        return null
    }
    val total = header.substring(slash + 1).trim()
    if (total == "*") {
        return null
    }
    return total.toLongOrNull()?.takeIf { it >= 0L }
}

/**
 * Delay before the retry that follows failure number [failureIndex].
 * Index 0 is the first failure and uses [RetryPolicy.initialBackoffMs].
 */
internal fun retryDelayMs(policy: RetryPolicy, failureIndex: Int): Long {
    val initial = policy.initialBackoffMs.coerceAtLeast(0L)
    val cap = policy.maxBackoffMs.coerceAtLeast(0L)
    if (failureIndex <= 0) {
        return initial.coerceAtMost(cap)
    }
    var delay = initial.toDouble()
    repeat(failureIndex) {
        delay *= policy.multiplier
        if (!delay.isFinite() || delay >= cap) {
            return cap
        }
    }
    return delay.toLong().coerceIn(0L, cap)
}

internal fun validateConfig(config: WorkTaskConfig): String? {
    if (config.taskId != config.taskId.trim() || !taskIdPattern.matches(config.taskId)) {
        return "taskId must contain 1 to 128 letters, digits, dots, underscores, hyphens, or colons."
    }
    val uri = try {
        URI(config.url)
    } catch (_: Exception) {
        null
    }
    if (uri == null || uri.scheme != "https" || uri.host.isNullOrEmpty()) {
        return "url must be an absolute https URL."
    }
    if (!isAbsolutePath(config.destinationPath)) {
        return "destinationPath must be an absolute file path."
    }
    if (config.method != HttpMethod.GET && !isTusUpload(config)) {
        return "Only GET downloads are supported in this version."
    }
    for ((name, value) in config.headers) {
        if (!headerNamePattern.matches(name) || controlCharacters.containsMatchIn(value)) {
            return "Header \"$name\" must use a token name and a value without control characters."
        }
    }
    if (config.retry.maxAttempts < 1L) {
        return "retry.maxAttempts must be at least 1."
    }
    if (config.retry.initialBackoffMs < 0L || config.retry.maxBackoffMs < config.retry.initialBackoffMs) {
        return "retry backoff must be non-negative and maxBackoff must cover initialBackoff."
    }
    if (!config.retry.multiplier.isFinite() || config.retry.multiplier < 1.0) {
        return "retry.multiplier must be a finite number >= 1."
    }
    return validateNotification(config.notification)
}

private fun validateNotification(notification: NotificationMetadata): String? {
    visibleText("notification.title", notification.title)?.let { return it }
    visibleText("notification.body", notification.body)?.let { return it }
    if (!channelIdPattern.matches(notification.channelId)) {
        return "notification.channelId must contain 1 to 128 letters, digits, dots, underscores, or hyphens."
    }
    return visibleText("notification.channelName", notification.channelName)
}

private fun visibleText(field: String, value: String): String? {
    if (value.trim().isEmpty() || controlCharacters.containsMatchIn(value)) {
        return "$field must be visible text without control characters."
    }
    return null
}

private fun isAbsolutePath(path: String): Boolean {
    if (path.isEmpty() || controlCharacters.containsMatchIn(path)) {
        return false
    }
    return path.startsWith("/") || path.startsWith("\\\\") || windowsAbsolute.containsMatchIn(path)
}

private val taskIdPattern = Regex("^[A-Za-z0-9._:-]{1,128}$")
private val channelIdPattern = Regex("^[A-Za-z0-9._-]{1,128}$")
private val headerNamePattern = Regex("^[A-Za-z0-9-]{1,128}$")
private val controlCharacters = Regex("[\\u0000-\\u001F\\u007F]")
private val windowsAbsolute = Regex("^[A-Za-z]:[\\\\/]")
