import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'speed_debug_log_session.dart';

/// Android MediaStore export — Kotlin [SpeedLimitApiRequestLogger.copySessionRequestsToPublicDownloads].
class LogExportPlatform {
  LogExportPlatform._();

  static const MethodChannel _ch = MethodChannel('speed_alert_pro/log_export');

  static Future<String?> copyUnifiedCsvToDownloads({
    required String sourcePath,
    required SpeedDebugLogSession session,
  }) async {
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final name = await _ch.invokeMethod<String>('copyUnifiedCsvToDownloads', <String, dynamic>{
        'sourcePath': sourcePath,
        'session': switch (session) {
          SpeedDebugLogSession.simulation => 'SIMULATION',
          SpeedDebugLogSession.driving => 'DRIVING',
          SpeedDebugLogSession.none => 'NONE',
        },
      });
      return name;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// HERE span session export as CSV to Downloads (Android Q+).
  static Future<String?> copySpanSessionCsvToDownloads({
    required String content,
    required SpeedDebugLogSession session,
  }) async {
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _ch.invokeMethod<String>('copySpanSessionCsvToDownloads', <String, dynamic>{
        'content': content,
        'session': switch (session) {
          SpeedDebugLogSession.simulation => 'SIMULATION',
          SpeedDebugLogSession.driving => 'DRIVING',
          SpeedDebugLogSession.none => 'NONE',
        },
      });
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// TomTom / Mapbox HTTP-only session CSV to Downloads (Android Q+).
  static Future<String?> copyProviderHttpSessionCsvToDownloads({
    required String content,
    required SpeedDebugLogSession session,
    required String provider,
  }) async {
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _ch.invokeMethod<String>('copyProviderHttpSessionCsvToDownloads', <String, dynamic>{
        'content': content,
        'session': switch (session) {
          SpeedDebugLogSession.simulation => 'SIMULATION',
          SpeedDebugLogSession.driving => 'DRIVING',
          SpeedDebugLogSession.none => 'NONE',
        },
        'provider': provider,
      });
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
