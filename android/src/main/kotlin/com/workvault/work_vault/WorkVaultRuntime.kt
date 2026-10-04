package com.workvault.work_vault

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.net.HttpURLConnection
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.android.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal sealed class DownloadOutcome {
    data object Completed : DownloadOutcome()

    data object Yielded : DownloadOutcome()

    data object Paused : DownloadOutcome()

    data object Cancelled : DownloadOutcome()

    data object Stopped : DownloadOutcome()

    data class Failed(
        val code: String,
        val message: String,
        val httpStatus: Int?,
        val retryable: Boolean,
    ) : DownloadOutcome()
}

internal object WorkVaultSignals {
    private val desired = ConcurrentHashMap<String, TaskStatus>()
    private val yield = ConcurrentHashMap.newKeySet<String>()
    private val connections = ConcurrentHashMap<String, HttpURLConnection>()

    fun setDesired(taskId: String, status: TaskStatus) {
        desired[taskId] = status
        if (status == TaskStatus.PAUSED || status == TaskStatus.CANCELLED) {
            interrupt(taskId)
        }
    }

    fun desired(taskId: String): TaskStatus? = desired[taskId]

    fun requestYield(taskIds: Collection<String>) {
        for (taskId in taskIds) {
            yield.add(taskId)
            interrupt(taskId)
        }
    }

    fun yieldRequested(taskId: String): Boolean = taskId in yield

    fun clearYield(taskId: String) {
        yield.remove(taskId)
    }

    fun bind(taskId: String, connection: HttpURLConnection) {
        connections[taskId] = connection
    }

    fun unbind(taskId: String, connection: HttpURLConnection) {
        connections.remove(taskId, connection)
    }

    private fun interrupt(taskId: String) {
        try {
            connections[taskId]?.disconnect()
        } catch (error: Exception) {
            Log.w(WorkVaultContract.tag, "Could not interrupt $taskId", error)
        }
    }
}

internal object WorkVaultRuns {
    private val locks = ConcurrentHashMap<String, Mutex>()

    suspend fun <T> tryRun(taskId: String, block: suspend () -> T): T? {
        val mutex = locks.getOrPut(taskId) { Mutex() }
        if (!mutex.tryLock()) {
            return null
        }
        try {
            return block()
        } finally {
            mutex.unlock()
        }
    }
}

internal object WorkVaultPermissions {
    fun notificationsGranted(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun dataSyncGranted(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.FOREGROUND_SERVICE_DATA_SYNC,
        ) == PackageManager.PERMISSION_GRANTED
    }
}

internal object WorkVaultRuntime {
    // Pigeon's FlutterApi calls into FlutterJNI, which is @UiThread. The main looper handler is
    // used directly because Dispatchers.Main resolves to a background pool when the Android
    // dispatcher factory is not loaded, which silently drops every event.
    private val emitScope = CoroutineScope(
        SupervisorJob() + Handler(Looper.getMainLooper()).asCoroutineDispatcher("work-vault-emit"),
    )
    private val gate = Mutex()

    @Volatile
    private var flutterApi: WorkVaultFlutterApi? = null

    @Volatile
    private var eventsReady: Boolean = false

    @Volatile
    private var initialized: Boolean = false

    fun attach(api: WorkVaultFlutterApi) {
        eventsReady = false
        flutterApi = api
    }

    fun detach() {
        eventsReady = false
        flutterApi = null
        initialized = false
    }

    fun markInitialized() {
        initialized = true
        eventsReady = true
    }

    suspend fun enqueue(context: Context, config: WorkTaskConfig): TaskSnapshot {
        requireInitialized()
        val problem = validateConfig(config)
        if (problem != null) {
            throw WorkVaultError(workVaultInvalidConfig, problem, null)
        }
        val record = TaskRecord(
            config = config,
            status = TaskStatus.ENQUEUED,
            bytesDownloaded = 0L,
            totalBytes = null,
            bytesPerSecond = 0.0,
            elapsedMs = 0L,
            failure = null,
            attemptCount = 0,
            acceptsRanges = null,
        )
        val inserted = WorkVaultStore.insertIfAbsent(context, record)
        if (!inserted) {
            throw duplicate(config.taskId)
        }
        if (!isTusUpload(config)) {
            File(config.destinationPath).takeIf { it.isFile }?.delete()
        }
        try {
            WorkVaultScheduler.enqueueNew(context, config)
        } catch (error: Exception) {
            WorkVaultStore.delete(context, config.taskId)
            throw WorkVaultError(
                workVaultTransferFailed,
                error.message ?: "Could not schedule the download.",
                mapOf<String, Any?>(
                    "taskId" to config.taskId,
                    "code" to "schedule",
                    "httpStatus" to null,
                    "retryable" to true,
                ),
            )
        }
        val snapshot = record.toSnapshot()
        emitStatus(context, record)
        return snapshot
    }

    suspend fun pause(context: Context, taskId: String) {
        requireInitialized()
        command(context, taskId, TaskCommand.PAUSE, stopWork = true)
    }

    suspend fun resume(context: Context, taskId: String) {
        requireInitialized()
        val updated = command(context, taskId, TaskCommand.RESUME, stopWork = false)
        WorkVaultScheduler.enqueueResume(context, updated.config)
    }

    suspend fun cancel(context: Context, taskId: String) {
        requireInitialized()
        val updated = command(context, taskId, TaskCommand.CANCEL, stopWork = true)
        if (!isTusUpload(updated.config)) {
            File(updated.config.destinationPath).takeIf { it.isFile }?.delete()
        }
        val cleared = updated.copy(bytesDownloaded = 0L, totalBytes = null, bytesPerSecond = 0.0)
        WorkVaultStore.put(context, cleared)
        emitStatus(context, cleared)
    }

    suspend fun getTask(context: Context, taskId: String): TaskSnapshot? {
        requireInitialized()
        return WorkVaultStore.get(context, taskId)?.toSnapshot()
    }

    suspend fun getTasks(context: Context): List<TaskSnapshot> {
        requireInitialized()
        return WorkVaultStore.all(context).map { it.toSnapshot() }
    }

    suspend fun markRunning(context: Context, record: TaskRecord): TaskRecord {
        WorkVaultSignals.setDesired(record.config.taskId, TaskStatus.RUNNING)
        WorkVaultSignals.clearYield(record.config.taskId)
        if (record.status == TaskStatus.RUNNING && record.failure == null) {
            return record
        }
        val running = record.copy(status = TaskStatus.RUNNING, failure = null)
        WorkVaultStore.put(context, running)
        emitStatus(context, running)
        return running
    }

    suspend fun reportProgress(
        context: Context,
        taskId: String,
        update: TransferProgressUpdate,
        foreground: Boolean,
    ) {
        val updated = WorkVaultStore.update(context, taskId) { current ->
            if (current.status.isTerminal() || current.status == TaskStatus.PAUSED) {
                current
            } else {
                current.copy(
                    bytesDownloaded = update.bytes,
                    totalBytes = update.totalBytes ?: current.totalBytes,
                    bytesPerSecond = update.bytesPerSecond,
                    elapsedMs = update.elapsedMs,
                    acceptsRanges = update.acceptsRanges ?: current.acceptsRanges,
                    etag = update.etag ?: current.etag,
                    expectedSha256 = update.expectedSha256 ?: current.expectedSha256,
                    expectedMd5 = update.expectedMd5 ?: current.expectedMd5,
                    tusLocation = update.tusLocation ?: current.tusLocation,
                    uploadOffset = update.uploadOffset ?: current.uploadOffset,
                )
            }
        } ?: return
        if (updated.status.isTerminal() || updated.status == TaskStatus.PAUSED) {
            return
        }
        emitProgress(context, updated)
        if (foreground) {
            WorkVaultNotifications.update(context, updated)
        }
    }

    suspend fun finish(context: Context, taskId: String, outcome: DownloadOutcome, mode: String): androidx.work.ListenableWorker.Result {
        val record = WorkVaultStore.get(context, taskId) ?: return androidx.work.ListenableWorker.Result.success()
        if (record.status == TaskStatus.PAUSED || record.status.isTerminal()) {
            return androidx.work.ListenableWorker.Result.success()
        }
        return when (outcome) {
            DownloadOutcome.Completed -> completeIfVerified(context, record, taskId)
            DownloadOutcome.Paused, DownloadOutcome.Cancelled -> androidx.work.ListenableWorker.Result.success()
            DownloadOutcome.Stopped -> {
                markEnqueued(context, record)
                androidx.work.ListenableWorker.Result.retry()
            }
            DownloadOutcome.Yielded -> {
                val enqueued = markEnqueued(context, record)
                if (mode != WorkVaultContract.modePeriodic) {
                    val quotaOpen = !dataSyncQuotaApplies(Build.VERSION.SDK_INT) || WorkVaultBudget.canStart(context)
                    WorkVaultScheduler.continueAfterYield(context, enqueued, quotaOpen)
                }
                androidx.work.ListenableWorker.Result.success()
            }
            is DownloadOutcome.Failed -> failOrRetry(context, record, outcome)
        }
    }

    suspend fun onWorkerStopped(context: Context, taskId: String): androidx.work.ListenableWorker.Result {
        val record = WorkVaultStore.get(context, taskId) ?: return androidx.work.ListenableWorker.Result.success()
        if (record.status.isTerminal() || record.status == TaskStatus.PAUSED) {
            return androidx.work.ListenableWorker.Result.success()
        }
        markEnqueued(context, record)
        return androidx.work.ListenableWorker.Result.retry()
    }

    fun onDataSyncTimeout(taskIds: Collection<String>) {
        WorkVaultSignals.requestYield(taskIds)
    }

    private suspend fun completeIfVerified(
        context: Context,
        record: TaskRecord,
        taskId: String,
    ): androidx.work.ListenableWorker.Result {
        val verdict = ChecksumVerifier.verify(
            file = File(record.config.destinationPath),
            expectedSha256 = record.expectedSha256,
            expectedMd5 = record.expectedMd5,
        )
        return when (verdict) {
            is ChecksumVerdict.Rejected -> failOrRetry(context, record, verdict.failure)
            is ChecksumVerdict.Verified -> {
                val completed = record.copy(
                    status = TaskStatus.COMPLETED,
                    failure = null,
                    sha256 = verdict.sha256,
                    md5 = verdict.md5,
                )
                WorkVaultStore.put(context, completed)
                emitStatus(context, completed)
                WorkVaultScheduler.cancelPeriodicWork(context, taskId)
                androidx.work.ListenableWorker.Result.success()
            }
        }
    }

    private suspend fun markEnqueued(context: Context, record: TaskRecord): TaskRecord {
        val enqueued = record.copy(status = TaskStatus.ENQUEUED, failure = null)
        WorkVaultStore.put(context, enqueued)
        emitStatus(context, enqueued)
        return enqueued
    }

    private suspend fun failOrRetry(
        context: Context,
        record: TaskRecord,
        outcome: DownloadOutcome.Failed,
    ): androidx.work.ListenableWorker.Result {
        val used = record.attemptCount + 1
        Log.w(
            WorkVaultContract.tag,
            "transfer ${record.config.taskId} failed attempt $used/${record.config.retry.maxAttempts} ${outcome.code}: ${outcome.message}",
        )
        if (!outcome.retryable || used >= record.config.retry.maxAttempts) {
            val failed = record.copy(
                status = TaskStatus.FAILED,
                attemptCount = used,
                failure = TaskFailure(
                    taskId = record.config.taskId,
                    code = outcome.code,
                    message = outcome.message,
                    httpStatus = outcome.httpStatus?.toLong(),
                    retryable = false,
                ),
            )
            WorkVaultStore.put(context, failed)
            emitStatus(context, failed)
            WorkVaultScheduler.cancelPeriodicWork(context, record.config.taskId)
            return androidx.work.ListenableWorker.Result.failure()
        }
        val waiting = record.copy(status = TaskStatus.ENQUEUED, attemptCount = used, failure = null)
        WorkVaultStore.put(context, waiting)
        emitStatus(context, waiting)
        WorkVaultScheduler.scheduleRetry(context, waiting, retryDelayMs(record.config.retry, record.attemptCount))
        return androidx.work.ListenableWorker.Result.success()
    }

    private suspend fun command(
        context: Context,
        taskId: String,
        command: TaskCommand,
        stopWork: Boolean,
    ): TaskRecord {
        val updated = gate.withLock {
            WorkVaultStore.mutate(context, taskId) { current ->
                if (current == null) {
                    throw missing(taskId)
                }
                val next = nextTaskStatus(current.status, command) ?: throw illegal(taskId, current.status, command)
                WorkVaultSignals.setDesired(taskId, next)
                current.copy(status = next, failure = null)
            }
        } ?: throw missing(taskId)
        emitStatus(context, updated)
        if (stopWork) {
            WorkVaultScheduler.cancelAll(context, taskId)
            WorkVaultForegroundService.stop(context, taskId)
        }
        return updated
    }

    private fun requireInitialized() {
        if (!initialized) {
            throw WorkVaultError(
                workVaultNotInitialized,
                "WorkVault.initialize must complete before tasks can be used.",
                null,
            )
        }
    }

    private fun emitStatus(context: Context, record: TaskRecord) {
        val api = flutterApi
        if (api != null) {
            if (!eventsReady) {
                return
            }
            val snapshot = record.toSnapshot()
            emitScope.launch {
                try {
                    api.onStatusChanged(snapshot)
                } catch (error: Throwable) {
                    Log.w(WorkVaultContract.tag, "onStatusChanged failed for ${snapshot.taskId}", error)
                }
            }
            return
        }
        WorkVaultEngineDispatcher.enqueue(context, record.toBackgroundEvent("status"))
    }

    private fun emitProgress(context: Context, record: TaskRecord) {
        val api = flutterApi
        if (api != null) {
            if (!eventsReady) {
                return
            }
            val progress = record.toProgress()
            emitScope.launch {
                try {
                    api.onProgress(progress)
                } catch (error: Throwable) {
                    Log.w(WorkVaultContract.tag, "onProgress failed for ${progress.taskId}", error)
                }
            }
            return
        }
        WorkVaultEngineDispatcher.enqueue(context, record.toBackgroundEvent("progress"))
    }

    private fun duplicate(taskId: String): WorkVaultError = WorkVaultError(
        workVaultDuplicateTask,
        "Task \"$taskId\" is already enqueued.",
        mapOf("taskId" to taskId),
    )

    private fun missing(taskId: String): WorkVaultError = WorkVaultError(
        workVaultTaskNotFound,
        "Task \"$taskId\" was not found.",
        mapOf("taskId" to taskId),
    )

    private fun illegal(taskId: String, from: TaskStatus, command: TaskCommand): WorkVaultError = WorkVaultError(
        workVaultIllegalTransition,
        "Cannot ${command.wireName()} task \"$taskId\" from ${from.wireName()}.",
        mapOf(
            "taskId" to taskId,
            "from" to from.wireName(),
            "action" to command.wireName(),
        ),
    )
}
