package com.example.speed_alert_pro

import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class DrivingLocationBridge(
    private val activity: android.app.Activity,
    engine: FlutterEngine,
) {
    private val method = MethodChannel(
        engine.dartExecutor.binaryMessenger,
        "speed_alert_pro/driving_location",
    )
    private val events = EventChannel(
        engine.dartExecutor.binaryMessenger,
        "speed_alert_pro/fused_location_stream",
    )

    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                DrivingLocationHub.eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                // EventChannel cancelled — do not stop the foreground service here (Dart stop/stopTracking does).
                DrivingLocationHub.eventSink = null
            }
        })

        method.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "isRunning" -> {
                    result.success(DrivingLocationServiceHolder.instance != null)
                }
                "start" -> {
                    ContextCompat.startForegroundService(
                        activity,
                        Intent(activity, DrivingLocationForegroundService::class.java),
                    )
                    result.success(null)
                }
                "stop" -> {
                    activity.stopService(Intent(activity, DrivingLocationForegroundService::class.java))
                    result.success(null)
                }
                "setPaused" -> {
                    val paused = call.arguments as? Boolean ?: false
                    DrivingLocationHub.fusedPaused = paused
                    DrivingLocationServiceHolder.instance?.applyLocationUpdatesState()
                    result.success(null)
                }
                "setSimulationActive" -> {
                    val active = call.arguments as? Boolean ?: false
                    DrivingLocationHub.simulationBlocking = active
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
        DrivingLocationHub.eventSink = null
        // Do not stop [DrivingLocationForegroundService] — survives Activity recreate / process death scenarios.
    }
}
