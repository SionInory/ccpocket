package com.nb.ccpocket

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.nb.ccpocket.netbird.Client
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class NetbirdBridge(context: Context) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val client = Client()
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> runAsync(result) {
                val managementUrl = call.argument<String>("managementUrl").orEmpty()
                val setupKey = call.argument<String>("setupKey").orEmpty()
                val deviceName = call.argument<String>("deviceName").orEmpty()
                client.start(
                    managementUrl,
                    setupKey,
                    deviceName,
                    File(appContext.filesDir, "netbird").absolutePath,
                )
                null
            }
            "stop" -> runAsync(result) {
                client.stop()
                null
            }
            "clearLogin" -> runAsync(result) {
                client.clearLogin()
                null
            }
            "status" -> runAsync(result) { client.status() }
            "proxyPort" -> runAsync(result) { client.proxyPort().toInt() }
            else -> result.notImplemented()
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error(
                        "netbird_error",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
        }
    }
}
