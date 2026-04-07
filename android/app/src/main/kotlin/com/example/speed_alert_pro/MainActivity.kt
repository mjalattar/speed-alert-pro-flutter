package com.example.speed_alert_pro

import android.content.Context
import android.os.SystemClock
import com.example.speed_alert_pro.prefs.SpeedAlertSharedPreferencesHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.sharedpreferences.Messages

class MainActivity : FlutterActivity() {

    private var overlay: SpeedOverlayBridge? = null
    private var logExport: LogExportBridge? = null
    private var drivingLocation: DrivingLocationBridge? = null
    private var speedAlertSound: SpeedAlertSoundBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Run migration before Dart reads prefs (first frame / SharedPreferences.getInstance).
        SpeedAlertSharedPreferencesHandler.migrateFromFlutterPluginStoreIfNeeded(applicationContext)
        super.configureFlutterEngine(flutterEngine)
        // After plugin registration: bind Pigeon to `SpeedAlertPrefs` (Kotlin [PreferencesManager] file).
        Messages.SharedPreferencesApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            SpeedAlertSharedPreferencesHandler(applicationContext),
        )
        overlay = SpeedOverlayBridge(this, flutterEngine)
        logExport = LogExportBridge(this, flutterEngine)
        drivingLocation = DrivingLocationBridge(this, flutterEngine)
        speedAlertSound = SpeedAlertSoundBridge(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "speed_alert_pro/system_clock").setMethodCallHandler { call, result ->
            when (call.method) {
                "elapsedRealtimeMs" -> result.success(SystemClock.elapsedRealtime().toInt())
                "elapsedRealtimeNanos" -> result.success(SystemClock.elapsedRealtimeNanos())
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "speed_alert_pro/overlay_permission").setMethodCallHandler { call, result ->
            when (call.method) {
                "primeAttemptAndOpenManageScreen" -> {
                    OverlayPermissionBridge.primeAttemptAndOpenManageScreen(this)
                    result.success(null)
                }
                "openManageOverlayScreen" -> {
                    OverlayPermissionBridge.openManageOverlayScreen(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "speed_alert_pro/speed_alert_prefs").setMethodCallHandler { call, result ->
            if (call.method != "commitStringMap") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            @Suppress("UNCHECKED_CAST")
            val raw = call.arguments as? Map<*, *>
            if (raw == null) {
                result.error("bad_args", "Expected string-keyed map", null)
                return@setMethodCallHandler
            }
            val prefs = applicationContext.getSharedPreferences(
                SpeedAlertSharedPreferencesHandler.SPEED_ALERT_PREFS_NAME,
                Context.MODE_PRIVATE,
            )
            val ed = prefs.edit()
            for ((k, v) in raw) {
                val key = k?.toString() ?: continue
                ed.putString(key, v?.toString() ?: "")
            }
            result.success(ed.commit())
        }
    }

    override fun onDestroy() {
        drivingLocation?.dispose()
        drivingLocation = null
        speedAlertSound?.dispose()
        speedAlertSound = null
        overlay?.release()
        overlay = null
        logExport?.dispose()
        logExport = null
        super.onDestroy()
    }
}
