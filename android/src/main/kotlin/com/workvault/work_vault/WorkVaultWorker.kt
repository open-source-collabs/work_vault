package com.workvault.work_vault

import android.content.Context
import android.os.Build
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * Chunked HTTPS download driven by WorkManager.
 *
 * Long transfers are elevated to [WorkVaultForegroundService] (`dataSync`). On Android 14+ the
 * service is bound by a 6-hour / 24-hour budget; this worker yields before the OS timeout and
 * continues with an expedited or periodic chunk. [isStopped] covers pause, cancel, and preemption.
 */
class WorkVaultWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {
    override val coroutineContext = Dispatchers.IO

    override suspend fun doWork(): Result {
        val taskId = inputData.getString(WorkVaultContract.keyTaskId) ?: return Result.failure()
        val mode = inputData.getString(WorkVaultContract.keyMode) ?: WorkVaultContract.modeForeground
        val existing = WorkVaultStore.get(applicationContext, taskId)
        if (existing == null || existing.status.isTerminal() || existing.status == TaskStatus.PAUSED) {
            if (existing?.status?.isTerminal() == true) {
                WorkVaultScheduler.cancelPeriodicWork(applicationContext, taskId)
            }
            return Result.success()
        }
        val result = WorkVaultRuns.tryRun(taskId) {
            execute(existing, mode)
        }
        return result ?: Result.retry()
    }

    private suspend fun execute(existing: TaskRecord, mode: String): Result {
        val running = WorkVaultRuntime.markRunning(applicationContext, existing)
        var sessionStart: Long? = null
        var lastBudgetWrite = 0L
        val foreground = elevate(running)
        if (foreground) {
            sessionStart = System.currentTimeMillis()
            WorkVaultBudget.open(applicationContext, sessionStart)
            lastBudgetWrite = sessionStart
        }
        try {
            val outcome = WorkVaultDownloader(
                context = applicationContext,
                workerStopped = { isStopped },
                onProgress = { update ->
                    WorkVaultRuntime.reportProgress(
                        context = applicationContext,
                        taskId = running.config.taskId,
                        update = update,
                        foreground = foreground,
                    )
                    val start = sessionStart
                    val now = System.currentTimeMillis()
                    if (foreground && start != null && now - lastBudgetWrite >= 15_000L) {
                        WorkVaultBudget.close(applicationContext, start, now)
                        lastBudgetWrite = now
                    }
                },
            ).download(running, foreground = foreground, sessionStartMs = sessionStart)
            return withContext(NonCancellable) {
                WorkVaultRuntime.finish(applicationContext, running.config.taskId, outcome, mode)
            }
        } catch (cancelled: CancellationException) {
            return withContext(NonCancellable) {
                WorkVaultRuntime.onWorkerStopped(applicationContext, running.config.taskId)
            }
        } finally {
            withContext(NonCancellable) {
                val start = sessionStart
                if (start != null) {
                    WorkVaultBudget.close(applicationContext, start, System.currentTimeMillis())
                }
                WorkVaultForegroundService.stop(applicationContext, running.config.taskId)
            }
        }
    }

    private suspend fun elevate(record: TaskRecord): Boolean {
        if (dataSyncQuotaApplies(Build.VERSION.SDK_INT)) {
            if (!WorkVaultPermissions.dataSyncGranted(applicationContext)) {
                return false
            }
            if (!WorkVaultBudget.canStart(applicationContext)) {
                return false
            }
        }
        return try {
            setForeground(WorkVaultNotifications.foregroundInfo(applicationContext, record))
            WorkVaultForegroundService.start(applicationContext, record.config.taskId)
            true
        } catch (error: Exception) {
            Log.w(WorkVaultContract.tag, "dataSync foreground unavailable for ${record.config.taskId}", error)
            false
        }
    }
}

internal class WorkVaultDownloader(
    private val context: Context,
    private val workerStopped: () -> Boolean,
    private val onProgress: suspend (TransferProgressUpdate) -> Unit,
) {
    suspend fun download(record: TaskRecord, foreground: Boolean, sessionStartMs: Long?): DownloadOutcome {
        val quotaYield: suspend () -> Boolean = {
            sessionStartMs != null &&
                dataSyncQuotaApplies(Build.VERSION.SDK_INT) &&
                WorkVaultBudget.shouldYield(context, sessionStartMs)
        }
        return when (transferKind(record.config)) {
            TransferKind.TUS_UPLOAD -> TusProtocolHandler(workerStopped, onProgress, quotaYield)
                .upload(record, foreground, sessionStartMs)
            TransferKind.RESUMABLE_GET -> ResumableEngine(workerStopped, onProgress, quotaYield)
                .download(record, foreground, sessionStartMs)
            TransferKind.UNSUPPORTED -> DownloadOutcome.Failed(
                "method",
                "Only GET downloads are supported in this version.",
                null,
                false,
            )
        }
    }
}