package com.example.speed_alert_pro

/** Lets [DrivingLocationBridge] pause/resume Fused updates without binding. */
object DrivingLocationServiceHolder {
    @Volatile
    var instance: DrivingLocationForegroundService? = null
}
