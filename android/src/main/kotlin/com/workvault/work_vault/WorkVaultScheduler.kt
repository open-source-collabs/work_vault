package com.workvault.work_vault

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkRequest
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit

internal object WorkVaultScheduler {
    fun enqueueNew(context: Context, config: WorkTaskConfig) {
        ensureWorkManager(context)
        cancelPeriodic(context, config.taskId)
        val request = buildOneTime(config, WorkVaultContract.modeForeground, expedite = false, delayMs = 0L)
        WorkManagerEnqueue.unique(
            context = context,
            name = WorkVaultContract.uniqueWorkName(config.taskId),
            policy = ExistingWorkPolicy.KEEP,
            request = request,
        )
    }

    fun enqueueResume(context: Context, config: WorkTaskConfig) {
        ensureWorkManager(context)
        cancelPeriodic(context, config.taskId)
        val request = buildOneTime(config, WorkVaultContract.modeForeground, expedite = false, delayMs = 0L)
        WorkManagerEnqueue.unique(
            context = context,
            name = WorkVaultContract.uniqueWorkName(config.taskId),
            policy = ExistingWorkPolicy.REPLACE,
            request = request,
        )
    }

    fun cancelAll(context: Context, taskId: String) {
        val manager = ensureWorkManager(context)
        manager.cancelUniqueWork(WorkVaultContract.uniqueWorkName(taskId))
        manager.cancelUniqueWork(WorkVaultContract.periodicWorkName(taskId))
    }

    fun cancelPeriodicWork(context: Context, taskId: String) {
        ensureWorkManager(context).cancelUniqueWork(WorkVaultContract.periodicWorkName(taskId))
    }

    fun continueAfterYield(context: Context, record: TaskRecord, quotaAvailable: Boolean) {
        ensureWorkManager(context)
        if (record.acceptsRanges == false && !quotaAvailable) {
            enqueuePeriodic(context, record.config)
            return
        }
        if (quotaAvailable) {
            cancelPeriodic(context, record.config.taskId)
            append(context, record.config, WorkVaultContract.modeForeground, expedite = false, delayMs = 0L)
            return
        }
        try {
            append(context, record.config, WorkVaultContract.modeChunk, expedite = true, delayMs = 0L)
            cancelPeriodic(context, record.config.taskId)
        } catch (error: RuntimeException) {
            Log.w(WorkVaultContract.tag, "Expedited chunk was rejected; using a bounded chunk", error)
            try {
                append(context, record.config, WorkVaultContract.modeChunk, expedite = false, delayMs = 0L)
            } catch (fallback: RuntimeException) {
                Log.w(WorkVaultContract.tag, "Unique work append failed; scheduling a periodic chunk", fallback)
                enqueuePeriodic(context, record.config)
            }
        }
    }

    fun scheduleRetry(context: Context, record: TaskRecord, delayMs: Long) {
        ensureWorkManager(context)
        append(
            context = context,
            config = record.config,
            mode = WorkVaultContract.modeForeground,
            expedite = false,
            delayMs = delayMs,
        )
    }

    private fun enqueuePeriodic(context: Context, config: WorkTaskConfig) {
        val request = PeriodicWorkRequestBuilder<WorkVaultWorker>(
            WorkVaultContract.periodicMinutes,
            TimeUnit.MINUTES,
        )
            .setConstraints(constraints(config))
            .setInputData(
                workDataOf(
                    WorkVaultContract.keyTaskId to config.taskId,
                    WorkVaultContract.keyMode to WorkVaultContract.modePeriodic,
                ),
            )
            .addTag(WorkVaultContract.workTag)
            .build()
        ensureWorkManager(context).enqueueUniquePeriodicWork(
            WorkVaultContract.periodicWorkName(config.taskId),
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }

    private fun append(context: Context, config: WorkTaskConfig, mode: String, expedite: Boolean, delayMs: Long) {
        val request = buildOneTime(config, mode, expedite, delayMs)
        WorkManagerEnqueue.unique(
            context = context,
            name = WorkVaultContract.uniqueWorkName(config.taskId),
            policy = ExistingWorkPolicy.APPEND,
            request = request,
        )
    }

    private fun buildOneTime(
        config: WorkTaskConfig,
        mode: String,
        expedite: Boolean,
        delayMs: Long,
    ): OneTimeWorkRequest {
        val backoff = retryDelayMs(config.retry, 0).coerceIn(10_000L, WorkRequest.MAX_BACKOFF_MILLIS)
        val builder = OneTimeWorkRequestBuilder<WorkVaultWorker>()
            .setConstraints(constraints(config))
            .setInputData(
                workDataOf(
                    WorkVaultContract.keyTaskId to config.taskId,
                    WorkVaultContract.keyMode to mode,
                ),
            )
            .addTag(WorkVaultContract.workTag)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, backoff, TimeUnit.MILLISECONDS)
        if (delayMs > 0L) {
            builder.setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
        }
        val batteryBlocksExpedite = config.battery.requiresCharging || config.battery.requiresBatteryNotLow
        if (expedite && delayMs == 0L && !batteryBlocksExpedite) {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        }
        return builder.build()
    }

    private fun constraints(config: WorkTaskConfig): Constraints {
        val network = when (config.network) {
            NetworkConstraint.ANY -> NetworkType.CONNECTED
            NetworkConstraint.UNMETERED -> NetworkType.UNMETERED
            NetworkConstraint.NOT_ROAMING -> NetworkType.NOT_ROAMING
        }
        return Constraints.Builder()
            .setRequiredNetworkType(network)
            .setRequiresCharging(config.battery.requiresCharging)
            .setRequiresBatteryNotLow(config.battery.requiresBatteryNotLow)
            .build()
    }

    private fun cancelPeriodic(context: Context, taskId: String) {
        cancelPeriodicWork(context, taskId)
    }
}

private object WorkManagerEnqueue {
    fun unique(context: Context, name: String, policy: ExistingWorkPolicy, request: OneTimeWorkRequest) {
        ensureWorkManager(context).enqueueUniqueWork(name, policy, request)
    }
}
