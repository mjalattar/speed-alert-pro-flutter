package com.example.speed_alert_pro

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Kotlin [SpeedAlertService.checkSpeedAlert] — debounced [ToneGenerator.TONE_PROP_BEEP].
 * Policy (audible + run mode + foreground) is applied in Dart; native only rate-limits playback.
 */
class SpeedAlertSoundBridge(engine: FlutterEngine) {
    private val channel = MethodChannel(
        engine.dartExecutor.binaryMessenger,
        "speed_alert_pro/speed_alert_sound",
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    private var toneGenerator: ToneGenerator? = ToneGenerator(AudioManager.STREAM_MUSIC, 80)
    private var lastAlertTimeMs: Long = 0

    init {
        channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "playDebounced" -> {
                    val minIntervalMs = (call.argument<Number>("minIntervalMs")?.toLong() ?: 3000L)
                    val durationMs = (call.argument<Number>("durationMs")?.toInt() ?: 200)
                    val now = System.currentTimeMillis()
                    // Kotlin [SpeedAlertService.checkSpeedAlert]: `currentTime - lastAlertTime > 3000` — block when <= 3000.
                    if (now - lastAlertTimeMs <= minIntervalMs) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    lastAlertTimeMs = now
                    mainHandler.post {
                        try {
                            Log.d("SpeedAlertService", "Playing tone alert")
                            toneGenerator?.startTone(ToneGenerator.TONE_PROP_BEEP, durationMs)
                        } catch (_: Exception) {
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        toneGenerator?.release()
        toneGenerator = null
    }
}
