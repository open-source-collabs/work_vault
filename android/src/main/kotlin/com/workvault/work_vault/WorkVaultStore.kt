package com.workvault.work_vault

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

internal data class TaskRecord(
    val config: WorkTaskConfig,
    val status: TaskStatus,
    val bytesDownloaded: Long,
    val totalBytes: Long?,
    val bytesPerSecond: Double,
    val elapsedMs: Long,
    val failure: TaskFailure?,
    val attemptCount: Int,
    val acceptsRanges: Boolean?,
    val etag: String? = null,
    val expectedSha256: String? = null,
    val expectedMd5: String? = null,
    val sha256: String? = null,
    val md5: String? = null,
    val tusLocation: String? = null,
    val uploadOffset: Long = 0L,
)

internal fun TaskRecord.toProgress(): TaskProgress = TaskProgress(
    taskId = config.taskId,
    bytesDownloaded = bytesDownloaded.coerceAtLeast(0L),
    totalBytes = totalBytes?.takeIf { it >= 0L },
    bytesPerSecond = bytesPerSecond.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0,
    elapsedMs = elapsedMs.coerceAtLeast(0L),
    percentage = percentageOf(bytesDownloaded, totalBytes),
)

internal fun TaskRecord.toSnapshot(): TaskSnapshot {
    val hasProgress = status == TaskStatus.RUNNING ||
        status == TaskStatus.COMPLETED ||
        bytesDownloaded > 0L ||
        elapsedMs > 0L
    return TaskSnapshot(
        taskId = config.taskId,
        status = status,
        progress = if (hasProgress) toProgress() else null,
        failure = if (status == TaskStatus.FAILED) failure else null,
    )
}

/**
 * Native state the headless isolate projects into SQLite.
 *
 * Every key is always present. A null means the store does not know the value, so the
 * projection clears a row that still carries an older one. This store stays the authority for
 * status, bytes, the entity tag, and the resume position those two fields describe.
 */
internal fun TaskRecord.toProjection(): Map<String, Any?> = linkedMapOf(
    "taskId" to config.taskId,
    "status" to status.wireName(),
    "filePath" to config.destinationPath,
    "downloadedBytes" to bytesDownloaded.coerceAtLeast(0L),
    "totalBytes" to totalBytes?.takeIf { it >= 0L },
    "eTag" to etag,
    "sha256" to sha256,
)

internal fun TaskRecord.toBackgroundEvent(kind: String): Map<String, Any?> {
    val payload = linkedMapOf<String, Any?>("kind" to kind)
    payload.putAll(toProjection())
    return payload
}

internal object WorkVaultStore {
    private val mutex = Mutex()

    suspend fun get(context: Context, taskId: String): TaskRecord? = mutex.withLock {
        read(context, taskId)
    }

    suspend fun put(context: Context, record: TaskRecord) {
        mutex.withLock {
            write(context, record)
        }
    }

    /** Inserts [record] when [TaskRecord.config.taskId] is free. Returns false when it already exists. */
    suspend fun insertIfAbsent(context: Context, record: TaskRecord): Boolean = mutex.withLock {
        if (read(context, record.config.taskId) != null) {
            return@withLock false
        }
        write(context, record)
        true
    }

    /**
     * Applies [block] while the store lock is held.
     * A null result leaves the file unchanged. Exceptions leave it unchanged too.
     */
    suspend fun mutate(context: Context, taskId: String, block: (TaskRecord?) -> TaskRecord?): TaskRecord? {
        return mutex.withLock {
            val current = read(context, taskId)
            val next = block(current) ?: return@withLock null
            write(context, next)
            next
        }
    }

    suspend fun delete(context: Context, taskId: String) {
        mutex.withLock {
            taskFile(context, taskId).delete()
        }
    }

    suspend fun update(context: Context, taskId: String, block: (TaskRecord) -> TaskRecord): TaskRecord? {
        return mutex.withLock {
            val current = read(context, taskId) ?: return@withLock null
            val next = block(current)
            write(context, next)
            next
        }
    }

    suspend fun all(context: Context): List<TaskRecord> = mutex.withLock {
        val directory = tasksDirectory(context)
        if (!directory.isDirectory) {
            return@withLock emptyList()
        }
        directory.listFiles()
            .orEmpty()
            .filter { it.isFile && it.extension == "json" }
            .mapNotNull { file ->
                try {
                    decode(JSONObject(file.readText(Charsets.UTF_8)))
                } catch (error: Exception) {
                    Log.w(WorkVaultContract.tag, "Skipping unreadable task file ${file.name}", error)
                    null
                }
            }
            .sortedBy { it.config.taskId }
    }

    private fun read(context: Context, taskId: String): TaskRecord? {
        val file = taskFile(context, taskId)
        if (!file.isFile) {
            return null
        }
        return try {
            decode(JSONObject(file.readText(Charsets.UTF_8)))
        } catch (error: Exception) {
            Log.w(WorkVaultContract.tag, "Could not read task $taskId", error)
            null
        }
    }

    private fun write(context: Context, record: TaskRecord) {
        val directory = tasksDirectory(context)
        if (!directory.isDirectory && !directory.mkdirs()) {
            error("Could not create ${directory.path}")
        }
        val destination = taskFile(context, record.config.taskId)
        val temporary = File(directory, destination.name + ".tmp")
        FileOutputStream(temporary).use { stream ->
            stream.write(encode(record).toString().toByteArray(Charsets.UTF_8))
            stream.fd.sync()
        }
        if (!temporary.renameTo(destination)) {
            destination.delete()
            if (!temporary.renameTo(destination)) {
                destination.writeText(temporary.readText(Charsets.UTF_8), Charsets.UTF_8)
                temporary.delete()
            }
        }
    }

    private fun tasksDirectory(context: Context): File {
        return File(context.applicationContext.filesDir, "work_vault/tasks")
    }

    private fun taskFile(context: Context, taskId: String): File {
        return File(tasksDirectory(context), fileName(taskId))
    }

    private fun fileName(taskId: String): String = taskId.replace(':', '~') + ".json"
}

internal object WorkVaultBudget {
    private val mutex = Mutex()

    suspend fun canStart(context: Context, nowMs: Long = System.currentTimeMillis()): Boolean = mutex.withLock {
        canStartDataSync(nowMs, read(context, nowMs))
    }

    suspend fun shouldYield(context: Context, sessionStartMs: Long, nowMs: Long = System.currentTimeMillis()): Boolean {
        return mutex.withLock {
            val closed = read(context, nowMs).filterNot { it.startMs == sessionStartMs }
            shouldYieldDataSync(nowMs, sessionStartMs, closed)
        }
    }

    suspend fun open(context: Context, startMs: Long) {
        mutex.withLock {
            val sessions = read(context, startMs).filterNot { it.startMs == startMs } + BudgetSession(startMs, startMs)
            write(context, sessions)
        }
    }

    suspend fun close(context: Context, startMs: Long, endMs: Long) {
        mutex.withLock {
            val end = endMs.coerceAtLeast(startMs)
            val sessions = read(context, end).filterNot { it.startMs == startMs } + BudgetSession(startMs, end)
            write(context, sessions)
        }
    }

    private fun read(context: Context, nowMs: Long): List<BudgetSession> {
        val file = budgetFile(context)
        if (!file.isFile) {
            return emptyList()
        }
        return try {
            val json = JSONObject(file.readText(Charsets.UTF_8))
            val array = json.optJSONArray("sessions") ?: return emptyList()
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val start = item.optLong("start", -1L)
                    val end = item.optLong("end", -1L)
                    if (start >= 0L && end >= start) {
                        add(BudgetSession(start, end))
                    }
                }
            }.filter { it.endMs >= nowMs - WorkVaultContract.dataSyncWindowMs }
        } catch (error: Exception) {
            Log.w(WorkVaultContract.tag, "Could not read the dataSync budget", error)
            emptyList()
        }
    }

    private fun write(context: Context, sessions: List<BudgetSession>) {
        val file = budgetFile(context)
        val directory = file.parentFile
        if (directory != null && !directory.isDirectory) {
            directory.mkdirs()
        }
        val array = org.json.JSONArray()
        for (session in sessions) {
            array.put(JSONObject().put("start", session.startMs).put("end", session.endMs))
        }
        file.writeText(JSONObject().put("sessions", array).toString(), Charsets.UTF_8)
    }

    private fun budgetFile(context: Context): File {
        return File(context.applicationContext.filesDir, "work_vault/data_sync_budget.json")
    }
}

private fun encode(record: TaskRecord): JSONObject {
    val config = record.config
    val headers = JSONObject()
    for ((name, value) in config.headers) {
        headers.put(name, value)
    }
    val retry = JSONObject()
        .put("maxAttempts", config.retry.maxAttempts)
        .put("initialBackoffMs", config.retry.initialBackoffMs)
        .put("maxBackoffMs", config.retry.maxBackoffMs)
        .put("multiplier", config.retry.multiplier)
    val battery = JSONObject()
        .put("requiresCharging", config.battery.requiresCharging)
        .put("requiresBatteryNotLow", config.battery.requiresBatteryNotLow)
    val notification = JSONObject()
        .put("title", config.notification.title)
        .put("body", config.notification.body)
        .put("channelId", config.notification.channelId)
        .put("channelName", config.notification.channelName)
    val root = JSONObject()
        .put("v", 1)
        .put("taskId", config.taskId)
        .put("url", config.url)
        .put("destinationPath", config.destinationPath)
        .put("method", config.method.wireName())
        .put("headers", headers)
        .put("network", config.network.wireName())
        .put("retry", retry)
        .put("battery", battery)
        .put("notification", notification)
        .put("status", record.status.wireName())
        .put("bytesDownloaded", record.bytesDownloaded)
        .put("bytesPerSecond", record.bytesPerSecond)
        .put("elapsedMs", record.elapsedMs)
        .put("attemptCount", record.attemptCount)
    root.putNullable("etag", record.etag)
    root.putNullable("expectedSha256", record.expectedSha256)
    root.putNullable("expectedMd5", record.expectedMd5)
    root.putNullable("sha256", record.sha256)
    root.putNullable("md5", record.md5)
    root.putNullable("tusLocation", record.tusLocation)
    root.put("uploadOffset", record.uploadOffset)
    if (record.totalBytes == null) {
        root.put("totalBytes", JSONObject.NULL)
    } else {
        root.put("totalBytes", record.totalBytes)
    }
    if (record.acceptsRanges == null) {
        root.put("acceptsRanges", JSONObject.NULL)
    } else {
        root.put("acceptsRanges", record.acceptsRanges)
    }
    val failure = record.failure
    if (failure == null) {
        root.put("failure", JSONObject.NULL)
    } else {
        val failureJson = JSONObject()
            .put("code", failure.code)
            .put("message", failure.message)
            .put("retryable", failure.retryable)
        if (failure.httpStatus == null) {
            failureJson.put("httpStatus", JSONObject.NULL)
        } else {
            failureJson.put("httpStatus", failure.httpStatus)
        }
        root.put("failure", failureJson)
    }
    return root
}

private fun decode(json: JSONObject): TaskRecord? {
    val taskId = json.optString("taskId")
    val status = taskStatusFromWire(json.optString("status")) ?: return null
    val method = httpMethodFromWire(json.optString("method")) ?: return null
    val network = networkFromWire(json.optString("network")) ?: return null
    val retryJson = json.optJSONObject("retry") ?: return null
    val batteryJson = json.optJSONObject("battery") ?: return null
    val notificationJson = json.optJSONObject("notification") ?: return null
    val headersJson = json.optJSONObject("headers") ?: JSONObject()
    val headers = linkedMapOf<String, String>()
    val names = headersJson.keys()
    while (names.hasNext()) {
        val name = names.next()
        headers[name] = headersJson.optString(name)
    }
    val config = WorkTaskConfig(
        taskId = taskId,
        url = json.optString("url"),
        destinationPath = json.optString("destinationPath"),
        method = method,
        headers = headers,
        network = network,
        retry = RetryPolicy(
            maxAttempts = retryJson.optLong("maxAttempts"),
            initialBackoffMs = retryJson.optLong("initialBackoffMs"),
            maxBackoffMs = retryJson.optLong("maxBackoffMs"),
            multiplier = retryJson.optDouble("multiplier"),
        ),
        battery = BatteryConstraint(
            requiresCharging = batteryJson.optBoolean("requiresCharging"),
            requiresBatteryNotLow = batteryJson.optBoolean("requiresBatteryNotLow"),
        ),
        notification = NotificationMetadata(
            title = notificationJson.optString("title"),
            body = notificationJson.optString("body"),
            channelId = notificationJson.optString("channelId"),
            channelName = notificationJson.optString("channelName"),
        ),
    )
    val failureJson = json.optJSONObject("failure")
    val failure = if (failureJson == null) {
        null
    } else {
        TaskFailure(
            taskId = taskId,
            code = failureJson.optString("code"),
            message = failureJson.optString("message"),
            httpStatus = if (failureJson.isNull("httpStatus")) null else failureJson.optLong("httpStatus"),
            retryable = failureJson.optBoolean("retryable"),
        )
    }
    return TaskRecord(
        config = config,
        status = status,
        bytesDownloaded = json.optLong("bytesDownloaded"),
        totalBytes = if (json.isNull("totalBytes")) null else json.optLong("totalBytes"),
        bytesPerSecond = json.optDouble("bytesPerSecond"),
        elapsedMs = json.optLong("elapsedMs"),
        failure = failure,
        attemptCount = json.optInt("attemptCount"),
        acceptsRanges = if (json.isNull("acceptsRanges")) null else json.optBoolean("acceptsRanges"),
        etag = json.nullableString("etag"),
        expectedSha256 = json.nullableString("expectedSha256"),
        expectedMd5 = json.nullableString("expectedMd5"),
        sha256 = json.nullableString("sha256"),
        md5 = json.nullableString("md5"),
        tusLocation = json.nullableString("tusLocation"),
        uploadOffset = json.optLong("uploadOffset"),
    )
}

private fun JSONObject.putNullable(key: String, value: String?) {
    if (value == null) {
        put(key, JSONObject.NULL)
    } else {
        put(key, value)
    }
}

private fun JSONObject.nullableString(key: String): String? {
    if (isNull(key)) {
        return null
    }
    return optString(key).ifEmpty { null }
}

private fun HttpMethod.wireName(): String = when (this) {
    HttpMethod.GET -> "get"
    HttpMethod.POST -> "post"
    HttpMethod.PUT -> "put"
    HttpMethod.HEAD -> "head"
}

private fun httpMethodFromWire(name: String): HttpMethod? = when (name) {
    "get" -> HttpMethod.GET
    "post" -> HttpMethod.POST
    "put" -> HttpMethod.PUT
    "head" -> HttpMethod.HEAD
    else -> null
}

private fun NetworkConstraint.wireName(): String = when (this) {
    NetworkConstraint.ANY -> "any"
    NetworkConstraint.UNMETERED -> "unmetered"
    NetworkConstraint.NOT_ROAMING -> "notRoaming"
}

private fun networkFromWire(name: String): NetworkConstraint? = when (name) {
    "any" -> NetworkConstraint.ANY
    "unmetered" -> NetworkConstraint.UNMETERED
    "notRoaming" -> NetworkConstraint.NOT_ROAMING
    else -> null
}
