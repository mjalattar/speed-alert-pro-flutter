package com.example.speed_alert_pro

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * Minimal parity with Kotlin [com.speedalertpro.SpeedOverlayController]:
 * TYPE_APPLICATION_OVERLAY, speed/limit text, − (minimize → Dart), × (stop tracking → Dart).
 */
class SpeedOverlayBridge(
    private val context: Context,
    flutterEngine: FlutterEngine,
) {
    private val appContext = context.applicationContext
    private val windowManager = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val density = appContext.resources.displayMetrics.density

    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "speed_alert_pro/overlay",
    )

    private var root: LinearLayout? = null

    private val colorIdle = 0xE6282830.toInt()
    private val colorSpeeding = 0xE6B71C1C.toInt()

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hide" -> {
                    mainHandler.post {
                        removeLocked()
                        result.success(null)
                    }
                }
                "update" -> {
                    val args = call.arguments as? Map<*, *>
                    mainHandler.post {
                        if (args == null) {
                            removeLocked()
                            result.success(null)
                            return@post
                        }
                        val speed = (args["speedMph"] as? Number)?.toDouble() ?: 0.0
                        val limit = (args["limitMph"] as? Number)?.toDouble()
                        val speeding = args["speeding"] as? Boolean ?: false
                        updateLocked(speed, limit, speeding)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun release() {
        mainHandler.post { removeLocked() }
    }

    private fun updateLocked(speedMph: Double, limitMph: Double?, isSpeeding: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || !Settings.canDrawOverlays(appContext)) {
            removeLocked()
            return
        }
        ensureAddedLocked()
        val r = root ?: return
        val speedTv = r.findViewWithTag<TextView>("speed")
        val limitTv = r.findViewWithTag<TextView>("limit")
        val card = r.findViewWithTag<LinearLayout>("card")
        speedTv?.text = "${speedMph.roundToInt()} mph"
        limitTv?.text = when {
            limitMph != null && limitMph > 0 -> "Limit ${limitMph.roundToInt()} mph"
            else -> "Limit —"
        }
        val bg = card?.background as? GradientDrawable
        if (isSpeeding) {
            bg?.setColor(colorSpeeding)
            speedTv?.setTextColor(Color.WHITE)
        } else {
            bg?.setColor(colorIdle)
            speedTv?.setTextColor(Color.WHITE)
        }
    }

    private fun ensureAddedLocked() {
        if (root != null) return
        val pad = (8 * density).toInt()
        val card = LinearLayout(appContext).apply {
            tag = "card"
            orientation = LinearLayout.VERTICAL
            val bg = GradientDrawable()
            bg.cornerRadius = 22f * density
            bg.setColor(colorIdle)
            background = bg
            setPadding(pad, pad, pad, pad)
        }
        val titleRow = LinearLayout(appContext).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        val btnMin = TextView(appContext).apply {
            text = "−"
            textSize = 18f
            setTextColor(Color.WHITE)
            setPadding(pad, 0, pad, 0)
            setOnClickListener {
                channel.invokeMethod("onMinimize", null)
            }
        }
        val btnClose = TextView(appContext).apply {
            text = "×"
            textSize = 18f
            setTextColor(Color.WHITE)
            setOnClickListener {
                channel.invokeMethod("onStopMonitoring", null)
            }
        }
        titleRow.addView(btnMin)
        titleRow.addView(btnClose)
        val speedTv = TextView(appContext).apply {
            tag = "speed"
            text = "— mph"
            textSize = 20f
            setTextColor(Color.WHITE)
        }
        val limitTv = TextView(appContext).apply {
            tag = "limit"
            text = "Limit —"
            textSize = 14f
            setTextColor(0xFFCCCCCC.toInt())
        }
        card.addView(titleRow)
        card.addView(speedTv)
        card.addView(limitTv)

        val wrap = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
            addView(card)
        }
        root = wrap

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
        val p = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            flags,
            PixelFormat.TRANSLUCENT,
        )
        p.gravity = Gravity.TOP or Gravity.END
        p.x = (16 * density).toInt()
        p.y = (88 * density).toInt()
        windowManager.addView(wrap, p)
    }

    private fun removeLocked() {
        val v = root ?: return
        try {
            windowManager.removeView(v)
        } catch (_: Exception) {
        }
        root = null
    }
}
