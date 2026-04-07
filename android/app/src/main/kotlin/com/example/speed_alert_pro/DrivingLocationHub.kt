package com.example.speed_alert_pro

import android.location.Location
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel

/**
 * Bridges Fused Location results to Flutter [EventChannel] on the main thread.
 * Kotlin [SpeedAlertService] parity: skip delivery while simulating or when fused paused (Normal + background).
 */
object DrivingLocationHub {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var eventSink: EventChannel.EventSink? = null

    @Volatile
    var simulationBlocking: Boolean = false

    @Volatile
    var fusedPaused: Boolean = false

    fun emit(location: Location) {
        if (simulationBlocking || fusedPaused) return
        val sink = eventSink ?: return
        val map = locationToMap(location)
        mainHandler.post {
            if (eventSink !== sink) return@post
            sink.success(map)
        }
    }

    private fun locationToMap(loc: Location): Map<String, Any?> {
        val sdk = android.os.Build.VERSION.SDK_INT
        val o = android.os.Build.VERSION_CODES.O
        val hasSpeed = loc.hasSpeed()
        val hasBearing = loc.hasBearing()
        val hasVert = sdk >= o && loc.hasVerticalAccuracy()
        val hasSpeedAcc = sdk >= o && loc.hasSpeedAccuracy()
        val hasBearAcc = sdk >= o && loc.hasBearingAccuracy()
        return mapOf(
            "latitude" to loc.latitude,
            "longitude" to loc.longitude,
            "timestampMs" to loc.time,
            "accuracy" to if (loc.hasAccuracy()) loc.accuracy.toDouble() else 0.0,
            "altitude" to loc.altitude,
            "altitudeAccuracy" to if (hasVert) loc.verticalAccuracyMeters.toDouble() else 0.0,
            "heading" to if (hasBearing) loc.bearing.toDouble() else 0.0,
            "headingAccuracy" to if (hasBearAcc) loc.bearingAccuracyDegrees.toDouble() else 0.0,
            "speed" to if (hasSpeed) loc.speed.toDouble() else 0.0,
            "speedAccuracy" to if (hasSpeedAcc) loc.speedAccuracyMetersPerSecond.toDouble() else 0.0,
            "isMocked" to when {
                sdk >= android.os.Build.VERSION_CODES.S -> loc.isMock
                sdk >= android.os.Build.VERSION_CODES.JELLY_BEAN_MR2 -> loc.isFromMockProvider
                else -> false
            },
            "elapsedRealtimeMs" to SystemClock.elapsedRealtime().toInt(),
            "elapsedRealtimeNanos" to SystemClock.elapsedRealtimeNanos(),
            "provider" to loc.provider.orEmpty(),
        )
    }
}
