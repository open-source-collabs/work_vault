package com.workvault.work_vault

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Pigeon host for work_vault.
 *
 * [initialize] must finish before [WorkVaultFlutterApi] events are delivered. The engine is
 * detached with the Flutter engine; scheduled work keeps running and is readable on the next
 * [initialize].
 */
class WorkVaultPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    WorkVaultHostApi {
    private var applicationContext: Context? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var permissionWaiter: CompletableDeferred<Boolean>? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        WorkVaultEngineDispatcher.bindUi(binding.binaryMessenger, binding.applicationContext)
        WorkVaultRuntime.attach(WorkVaultFlutterApi(binding.binaryMessenger))
        WorkVaultHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        WorkVaultHostApi.setUp(binding.binaryMessenger, null)
        WorkVaultEngineDispatcher.unbindUi()
        WorkVaultRuntime.detach()
        applicationContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != WorkVaultContract.permissionRequestCode) {
            return false
        }
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionWaiter?.complete(granted)
        permissionWaiter = null
        return true
    }

    override suspend fun initialize() {
        val context = applicationContext ?: throw WorkVaultError(
            workVaultNotInitialized,
            "WorkVault.initialize must complete before tasks can be used.",
            null,
        )
        ensureWorkManager(context)
        requestPostNotifications(context)
        if (!WorkVaultPermissions.dataSyncGranted(context)) {
            Log.w(
                WorkVaultContract.tag,
                "FOREGROUND_SERVICE_DATA_SYNC is not granted; long downloads will use chunked work.",
            )
        }
        WorkVaultRuntime.markInitialized()
    }

    override suspend fun enqueue(config: WorkTaskConfig): TaskSnapshot {
        return WorkVaultRuntime.enqueue(requireContext(), config)
    }

    override suspend fun pause(taskId: String) {
        WorkVaultRuntime.pause(requireContext(), taskId)
    }

    override suspend fun resume(taskId: String) {
        WorkVaultRuntime.resume(requireContext(), taskId)
    }

    override suspend fun cancel(taskId: String) {
        WorkVaultRuntime.cancel(requireContext(), taskId)
    }

    override suspend fun getTask(taskId: String): TaskSnapshot? {
        return WorkVaultRuntime.getTask(requireContext(), taskId)
    }

    override suspend fun getTasks(): List<TaskSnapshot> {
        return WorkVaultRuntime.getTasks(requireContext())
    }

    private suspend fun requestPostNotifications(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (WorkVaultPermissions.notificationsGranted(context)) {
            return
        }
        val activity = activityBinding?.activity ?: run {
            Log.w(WorkVaultContract.tag, "POST_NOTIFICATIONS was not requested because no activity is attached.")
            return
        }
        val waiter = CompletableDeferred<Boolean>()
        permissionWaiter = waiter
        activity.runOnUiThread {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                WorkVaultContract.permissionRequestCode,
            )
        }
        val granted = withTimeoutOrNull(120_000) { waiter.await() }
        if (permissionWaiter === waiter) {
            permissionWaiter = null
        }
        if (granted != true) {
            Log.w(WorkVaultContract.tag, "POST_NOTIFICATIONS was denied; progress notifications may be hidden.")
        }
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        permissionWaiter?.complete(false)
        permissionWaiter = null
    }

    private fun requireContext(): Context {
        return applicationContext ?: throw WorkVaultError(
            workVaultNotInitialized,
            "WorkVault.initialize must complete before tasks can be used.",
            null,
        )
    }
}
