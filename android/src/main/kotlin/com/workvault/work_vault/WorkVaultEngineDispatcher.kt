package com.workvault.work_vault

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Starts [workVaultBackgroundMain] when a worker emits and the UI engine is gone.
 *
 * The UI engine and the headless engine each own a messenger. Events are queued
 * on the platform thread and delivered on `com.workvault.work_vault/background`.
 */
internal object WorkVaultEngineDispatcher {
    const val channelName = "com.workvault.work_vault/background"
    const val entrypoint = "workVaultBackgroundMain"
    const val libraryUri = "package:work_vault/src/isolate/background_entry_point.dart"

    private const val prefsName = "work_vault_background"
    private const val handlerKey = "callback_handle"
    private const val readyTimeoutMs = 30_000L

    private val main = Handler(Looper.getMainLooper())
    private val pending = mutableListOf<Map<String, Any?>>()

    private var uiChannel: MethodChannel? = null
    private var engine: FlutterEngine? = null
    private var headlessChannel: MethodChannel? = null
    private var appContext: Context? = null
    private var ready = false
    private var starting = false
    private var inFlight = false
    private var idleShutdown: Runnable? = null

    /** Keeps one headless engine for a short burst of progress and status events. */
    private const val idleShutdownMs = 2_000L

    fun bindUi(messenger: BinaryMessenger, context: Context) {
        val application = context.applicationContext
        appContext = application
        val channel = MethodChannel(messenger, channelName)
        channel.setMethodCallHandler { call, result -> handleUi(application, call, result) }
        uiChannel = channel
    }

    fun unbindUi() {
        uiChannel?.setMethodCallHandler(null)
        uiChannel = null
    }

    fun enqueue(context: Context, event: Map<String, Any?>) {
        val application = context.applicationContext
        main.post {
            appContext = application
            offer(event)
            ensureEngine(application)
            if (ready) {
                pump()
            }
        }
    }

    private fun handleUi(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "databasePath" -> result.success(databaseFile(context).absolutePath)
            "registerHandler" -> {
                val handle = asLong(call.arguments)
                if (handle == null) {
                    result.error(workVaultInvalidConfig, "The callback handle is missing.", null)
                    return
                }
                context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
                    .edit()
                    .putLong(handlerKey, handle)
                    .apply()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun offer(event: Map<String, Any?>) {
        if (event["kind"] == "progress") {
            val index = pending.indexOfLast { queued ->
                queued["kind"] == "progress" && queued["taskId"] == event["taskId"]
            }
            if (index >= 0) {
                pending.removeAt(index)
            }
        }
        pending.add(event)
    }

    private fun ensureEngine(context: Context) {
        if (engine != null || starting) {
            return
        }
        starting = true
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
            val created = FlutterEngine(context)
            val channel = MethodChannel(created.dartExecutor.binaryMessenger, channelName)
            channel.setMethodCallHandler { call, result ->
                if (call.method == "ready") {
                    ready = true
                    result.success(null)
                    pump()
                } else {
                    result.notImplemented()
                }
            }
            headlessChannel = channel
            engine = created
            created.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    libraryUri,
                    entrypoint,
                ),
            )
            main.postDelayed({
                if (!ready && engine === created) {
                    Log.e(WorkVaultContract.tag, "Headless engine did not become ready")
                    pending.clear()
                    teardown()
                }
            }, readyTimeoutMs)
        } catch (error: Throwable) {
            Log.e(WorkVaultContract.tag, "Headless engine failed to start", error)
            teardown()
        }
    }

    private fun pump() {
        if (!ready || inFlight) {
            return
        }
        val context = appContext
        val channel = headlessChannel
        if (context == null || channel == null) {
            return
        }
        if (pending.isEmpty()) {
            scheduleShutdown()
            return
        }
        cancelIdleShutdown()
        val next = pending.removeAt(0)
        inFlight = true
        val payload = LinkedHashMap<String, Any?>(next)
        payload["databasePath"] = databaseFile(context).absolutePath
        val handle = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .getLong(handlerKey, 0L)
        if (handle != 0L) {
            payload["callbackHandle"] = handle
        }
        channel.invokeMethod(
            "dispatch",
            payload,
            object : MethodChannel.Result {
                override fun success(result: Any?) = finishOne()

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    Log.w(WorkVaultContract.tag, "Background dispatch failed: $errorMessage")
                    finishOne()
                }

                override fun notImplemented() = finishOne()
            },
        )
    }

    private fun finishOne() {
        main.post {
            inFlight = false
            if (pending.isEmpty()) {
                scheduleShutdown()
            } else {
                pump()
            }
        }
    }

    private fun scheduleShutdown() {
        if (idleShutdown != null || engine == null) {
            return
        }
        val task = Runnable {
            idleShutdown = null
            if (inFlight || pending.isNotEmpty() || engine == null || !ready) {
                return@Runnable
            }
            shutdown()
        }
        idleShutdown = task
        main.postDelayed(task, idleShutdownMs)
    }

    private fun cancelIdleShutdown() {
        idleShutdown?.let(main::removeCallbacks)
        idleShutdown = null
    }

    private fun shutdown() {
        val channel = headlessChannel
        val running = engine
        if (channel == null || running == null) {
            teardown()
            return
        }
        inFlight = true
        channel.invokeMethod(
            "shutdown",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) = completeShutdown(running)

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    completeShutdown(running)
                }

                override fun notImplemented() = completeShutdown(running)
            },
        )
    }

    private fun completeShutdown(running: FlutterEngine) {
        main.post {
            inFlight = false
            if (engine !== running) {
                return@post
            }
            if (pending.isNotEmpty()) {
                pump()
                return@post
            }
            teardown()
        }
    }

    private fun teardown() {
        cancelIdleShutdown()
        ready = false
        starting = false
        inFlight = false
        headlessChannel?.setMethodCallHandler(null)
        headlessChannel = null
        val running = engine
        engine = null
        if (running != null) {
            running.destroy()
            Log.i(WorkVaultContract.tag, "Headless engine shut down")
        }
    }

    private fun databaseFile(context: Context): File {
        val directory = File(context.filesDir, "work_vault")
        if (!directory.isDirectory) {
            directory.mkdirs()
        }
        return File(directory, "work_vault.db")
    }

    private fun asLong(value: Any?): Long? = when (value) {
        is Long -> value
        is Int -> value.toLong()
        is Number -> value.toLong()
        else -> null
    }
}
