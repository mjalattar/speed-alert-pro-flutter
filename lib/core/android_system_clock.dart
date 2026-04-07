import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android [SystemClock] elapsed realtime via [MainActivity] MethodChannel.
class AndroidSystemClock {
  AndroidSystemClock._();

  static const MethodChannel _ch = MethodChannel('speed_alert_pro/system_clock');

  static Future<int?> elapsedRealtimeMs() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final v = await _ch.invokeMethod<dynamic>('elapsedRealtimeMs');
      if (v is int) return v;
      if (v is num) return v.toInt();
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Monotonic nanoseconds since boot; used with [SpeedLimitLoggingContext] fix age.
  static Future<int?> elapsedRealtimeNanos() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final v = await _ch.invokeMethod<dynamic>('elapsedRealtimeNanos');
      if (v is int) return v;
      if (v is num) return v.toInt();
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
