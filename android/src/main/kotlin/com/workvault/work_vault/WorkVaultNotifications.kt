package com.workvault.work_vault

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.ForegroundInfo
import java.util.concurrent.ConcurrentHashMap

internal object WorkVaultNotifications {
    private val cache = ConcurrentHashMap<String, Notification>()

    fun foregroundInfo(context: Context, record: TaskRecord): ForegroundInfo {
        val notification = build(context, record)
        val id = WorkVaultContract.notificationId(record.config.taskId)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(id, notification)
        }
    }

    fun update(context: Context, record: TaskRecord) {
        val notification = build(context, record)
        NotificationManagerCompat.from(context).notify(
            WorkVaultContract.notificationId(record.config.taskId),
            notification,
        )
    }

    fun cachedOrPlaceholder(context: Context, taskId: String): Notification {
        return cache[taskId] ?: placeholder(context, taskId)
    }

    private fun build(context: Context, record: TaskRecord): Notification {
        val metadata = record.config.notification
        ensureChannel(context, metadata.channelId, metadata.channelName)
        val percentage = percentageOf(record.bytesDownloaded, record.totalBytes)
        val indeterminate = percentage == null
        val progress = percentage?.toInt() ?: 0
        val detail = if (record.totalBytes != null && record.totalBytes > 0L) {
            "${formatBytes(record.bytesDownloaded)} / ${formatBytes(record.totalBytes)}"
        } else {
            formatBytes(record.bytesDownloaded)
        }
        val notification = NotificationCompat.Builder(context, metadata.channelId)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(metadata.title)
            .setContentText("${metadata.body} · $detail")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setProgress(100, progress, indeterminate)
            .setContentIntent(launchIntent(context))
            .build()
        cache[record.config.taskId] = notification
        return notification
    }

    private fun placeholder(context: Context, taskId: String): Notification {
        ensureChannel(context, "work_vault", "Work Vault")
        return NotificationCompat.Builder(context, "work_vault")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Download")
            .setContentText(taskId)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun ensureChannel(context: Context, channelId: String, channelName: String) {
        val channel = NotificationChannelCompat.Builder(channelId, NotificationManagerCompat.IMPORTANCE_LOW)
            .setName(channelName)
            .setShowBadge(false)
            .build()
        NotificationManagerCompat.from(context).createNotificationChannel(channel)
    }

    private fun launchIntent(context: Context): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        return PendingIntent.getActivity(
            context,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun formatBytes(bytes: Long): String {
        val value = bytes.coerceAtLeast(0L).toDouble()
        val units = arrayOf("B", "KB", "MB", "GB")
        var size = value
        var unit = 0
        while (size >= 1024.0 && unit < units.lastIndex) {
            size /= 1024.0
            unit += 1
        }
        return if (unit == 0) {
            "${size.toLong()} ${units[unit]}"
        } else {
            String.format(java.util.Locale.US, "%.1f %s", size, units[unit])
        }
    }
}
