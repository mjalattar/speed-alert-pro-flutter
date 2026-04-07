package com.example.speed_alert_pro

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.WindowManager

/** 1×1 overlay prime + OEM overlay settings intents for “draw over other apps”. */
object OverlayPermissionBridge {

    private const val TAG = "OverlayPermission"

    fun primeAttemptAndOpenManageScreen(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (Settings.canDrawOverlays(activity)) return
        activity.runOnUiThread {
            try {
                val wm = activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val probe = View(activity)
                val lp = WindowManager.LayoutParams(
                    1,
                    1,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                    PixelFormat.TRANSPARENT,
                )
                wm.addView(probe, lp)
                wm.removeView(probe)
            } catch (e: Exception) {
                Log.d(TAG, "Overlay prime (expected without permission): ${e.javaClass.simpleName}")
            }
            openManageOverlayScreen(activity)
        }
    }

    fun openManageOverlayScreen(context: Context) {
        val pkg = context.packageName
        val uri = Uri.parse("package:$pkg")
        val candidates = listOf(
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, uri),
            Intent("android.settings.action.MANAGE_OVERLAY_PERMISSION", uri).takeIf {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
            },
        ).filterNotNull()

        val newTask = if (context !is Activity) Intent.FLAG_ACTIVITY_NEW_TASK else 0
        for (intent in candidates) {
            try {
                if (newTask != 0) intent.addFlags(newTask)
                context.startActivity(intent)
                return
            } catch (e: Exception) {
                Log.w(TAG, "Overlay intent failed: ${intent.action}", e)
            }
        }
        try {
            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", pkg, null)
                if (newTask != 0) addFlags(newTask)
            }
            context.startActivity(fallback)
        } catch (e: Exception) {
            Log.e(TAG, "App details fallback failed", e)
        }
    }
}
