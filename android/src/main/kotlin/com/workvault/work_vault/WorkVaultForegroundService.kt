package com.workvault.work_vault

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Persistent `dataSync` notification host for an elevated download.
 *
 * Android 15 calls [onTimeout] when `dataSync` foreground time is exhausted (6 hours in a
 * 24-hour window). The service stops immediately and asks the worker to checkpoint into an
 * expedited or periodic chunk instead of being killed.
 */
class WorkVaultForegroundService : Service() {
    private val yielded = AtomicBoolean(false)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val taskId = intent?.getStringExtra(EXTRA_TASK_ID)
        when (intent?.action) {
            ACTION_STOP -> {
                if (taskId != null) {
                    active.remove(taskId)
                }
                val remaining = active.firstOrNull()
                if (remaining == null) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                } else {
                    promote(remaining)
                }
            }
            else -> {
                if (taskId == null) {
                    if (active.isEmpty()) {
                        stopSelf()
                    }
                } else {
                    active.add(taskId)
                    promote(taskId)
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int) {
        yieldAndStop()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        yieldAndStop()
    }

    override fun onDestroy() {
        active.clear()
        super.onDestroy()
    }

    private fun promote(taskId: String) {
        val notification = WorkVaultNotifications.cachedOrPlaceholder(this, taskId)
        val id = WorkVaultContract.notificationId(taskId)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(id, notification)
            }
        } catch (error: Exception) {
            Log.e(WorkVaultContract.tag, "startForeground failed for $taskId", error)
            active.remove(taskId)
            stopSelf()
        }
    }

    private fun yieldAndStop() {
        if (!yielded.compareAndSet(false, true)) {
            return
        }
        val tasks = active.toList()
        Log.i(WorkVaultContract.tag, "dataSync time limit reached for ${tasks.size} task(s)")
        WorkVaultRuntime.onDataSyncTimeout(tasks)
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (error: Exception) {
            Log.w(WorkVaultContract.tag, "stopForeground during timeout failed", error)
        }
        stopSelf()
    }

    companion object {
        private const val ACTION_START = "com.workvault.work_vault.action.START"
        private const val ACTION_STOP = "com.workvault.work_vault.action.STOP"
        private const val EXTRA_TASK_ID = "taskId"
        private val active = ConcurrentHashMap.newKeySet<String>()

        fun start(context: Context, taskId: String) {
            active.add(taskId)
            val intent = Intent(context, WorkVaultForegroundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TASK_ID, taskId)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context, taskId: String) {
            active.remove(taskId)
            val intent = Intent(context, WorkVaultForegroundService::class.java)
                .setAction(ACTION_STOP)
                .putExtra(EXTRA_TASK_ID, taskId)
            try {
                context.startService(intent)
            } catch (error: IllegalStateException) {
                Log.w(WorkVaultContract.tag, "Foreground service was already stopped", error)
            }
        }
    }
}
