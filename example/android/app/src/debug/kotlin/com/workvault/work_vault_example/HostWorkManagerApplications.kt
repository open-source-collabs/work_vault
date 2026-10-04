package com.workvault.work_vault_example

import android.app.Application
import android.content.Context
import android.util.Log
import androidx.work.Configuration
import androidx.work.ListenableWorker
import androidx.work.WorkManager
import androidx.work.WorkerFactory
import androidx.work.WorkerParameters

private const val HOST_TAG = "WorkVaultHost"

/**
 * Host that owns WorkManager and returns null for workers it does not know, like a Hilt or
 * Dagger factory. WorkManager then falls back to reflection for plugin workers.
 */
private class HostWorkerFactory : WorkerFactory() {
    override fun createWorker(
        appContext: Context,
        workerClassName: String,
        workerParameters: WorkerParameters,
    ): ListenableWorker? {
        Log.i(HOST_TAG, "Host factory asked for $workerClassName")
        return null
    }
}

private fun hostConfiguration(): Configuration = Configuration.Builder()
    .setMinimumLoggingLevel(Log.INFO)
    .setWorkerFactory(HostWorkerFactory())
    .build()

/** Host that calls [WorkManager.initialize] itself in [onCreate]. Selected with WORK_VAULT_HOST_INIT=manual. */
class ManualWorkManagerApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        WorkManager.initialize(this, hostConfiguration())
        Log.i(HOST_TAG, "Host initialized WorkManager in Application.onCreate")
    }
}

/** Host that supplies on-demand configuration. Selected with WORK_VAULT_HOST_INIT=provider. */
class ProviderWorkManagerApplication : Application(), Configuration.Provider {
    override val workManagerConfiguration: Configuration
        get() {
            Log.i(HOST_TAG, "Host supplied WorkManager configuration")
            return hostConfiguration()
        }
}
