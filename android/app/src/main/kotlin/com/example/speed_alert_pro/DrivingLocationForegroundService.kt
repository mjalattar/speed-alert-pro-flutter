package com.example.speed_alert_pro

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.Looper
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

/**
 * Foreground service + Google Play Fused Location
 * (200 ms interval, 100 ms min, 0 m displacement, high accuracy).
 */
class DrivingLocationForegroundService : Service() {

    private lateinit var fused: FusedLocationProviderClient
    private lateinit var callback: LocationCallback
    private var updatesActive = false

    override fun onCreate() {
        super.onCreate()
        fused = LocationServices.getFusedLocationProviderClient(this)
        callback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                for (loc in result.locations) {
                    DrivingLocationHub.emit(loc)
                }
            }
        }
        createChannel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        DrivingLocationServiceHolder.instance = this
        startForeground(NOTIFICATION_ID, buildNotification())
        applyLocationUpdatesState()
        return START_STICKY
    }

    @SuppressLint("MissingPermission")
    fun applyLocationUpdatesState() {
        if (DrivingLocationHub.fusedPaused) {
            stopLocationUpdatesInternal()
            return
        }
        if (updatesActive) return
        val builder = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 200L)
            .setMinUpdateIntervalMillis(100L)
            .setMinUpdateDistanceMeters(0f)
            .setMaxUpdateDelayMillis(0L)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setWaitForAccurateLocation(false)
        }
        fused.requestLocationUpdates(
            builder.build(),
            callback,
            Looper.getMainLooper(),
        )
        updatesActive = true
    }

    private fun stopLocationUpdatesInternal() {
        if (!updatesActive) return
        try {
            fused.removeLocationUpdates(callback)
        } catch (_: Exception) {
        }
        updatesActive = false
    }

    override fun onDestroy() {
        stopLocationUpdatesInternal()
        if (DrivingLocationServiceHolder.instance === this) {
            DrivingLocationServiceHolder.instance = null
        }
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java)
        val ch = NotificationChannel(
            CHANNEL_ID,
            "Driving location",
            NotificationManager.IMPORTANCE_LOW,
        )
        ch.setShowBadge(false)
        mgr.createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Speed Alert Pro")
            .setContentText("Tracking speed and location")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "speed_alert_fused_location"
        private const val NOTIFICATION_ID = 7101
    }
}
