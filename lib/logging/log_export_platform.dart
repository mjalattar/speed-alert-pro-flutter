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

  /// Kotlin [HereSpanFetchSessionLogger] text export to Downloads (Android Q+).
  static Future<String?> copySpanSessionTxtToDownloads({
    required String content,
    required SpeedDebugLogSession session,
  }) async {
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _ch.invokeMethod<String>('copySpanSessionTxtToDownloads', <String, dynamic>{
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
}
