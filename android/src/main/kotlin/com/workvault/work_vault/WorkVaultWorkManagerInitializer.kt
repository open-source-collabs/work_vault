package com.workvault.work_vault

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import androidx.startup.Initializer
import androidx.work.Configuration
import androidx.work.ListenableWorker
import androidx.work.WorkManager
import androidx.work.WorkerFactory
import androidx.work.WorkerParameters

/**
 * Replaces [androidx.work.WorkManagerInitializer] so this plugin can install [WorkVaultWorkerFactory].
 *
 * A host that initializes WorkManager itself sets [HOST_OWNS_WORK_MANAGER] to true. Startup then
 * leaves that instance alone. [ensureWorkManager] still uses it, and the default factory builds
 * [WorkVaultWorker] when the host factory returns null.
 */
class WorkVaultWorkManagerInitializer : Initializer<Boolean> {
    override fun create(context: Context): Boolean {
        if (hostOwnsWorkManager(context)) {
            val app = context.applicationContext
            if (app is Configuration.Provider) {
                WorkManager.getInstance(app)
                Log.i(WorkVaultContract.tag, "Using the host WorkManager configuration")
            } else {
                Log.i(
                    WorkVaultContract.tag,
                    "Host owns WorkManager; waiting for Application.onCreate",
                )
            }
            return true
        }
        ensureWorkManager(context)
        return true
    }

    override fun dependencies(): List<Class<out Initializer<*>>> = emptyList()
}

/** Application meta-data. True when the host initializes WorkManager itself. */
internal const val HOST_OWNS_WORK_MANAGER = "com.workvault.work_vault.HostOwnsWorkManager"

internal fun hostOwnsWorkManager(context: Context): Boolean {
    val raw = try {
        context.packageManager.getApplicationInfo(
            context.packageName,
            PackageManager.GET_META_DATA,
        ).metaData?.get(HOST_OWNS_WORK_MANAGER)
    } catch (_: Exception) {
        null
    } ?: return false
    return raw == true || raw.toString().equals("true", ignoreCase = true)
}

internal class WorkVaultWorkerFactory : WorkerFactory() {
    override fun createWorker(
        appContext: Context,
        workerClassName: String,
        workerParameters: WorkerParameters,
    ): ListenableWorker? {
        if (workerClassName != WorkVaultWorker::class.java.name) {
            return null
        }
        return WorkVaultWorker(appContext, workerParameters)
    }
}

internal fun ensureWorkManager(context: Context): WorkManager {
    val appContext = context.applicationContext
    return try {
        WorkManager.getInstance(appContext)
    } catch (_: IllegalStateException) {
        Log.i(WorkVaultContract.tag, "Initializing WorkManager")
        WorkManager.initialize(
            appContext,
            Configuration.Builder()
                .setMinimumLoggingLevel(Log.INFO)
                .setWorkerFactory(WorkVaultWorkerFactory())
                .build(),
        )
        WorkManager.getInstance(appContext)
    }
}
