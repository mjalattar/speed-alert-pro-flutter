import 'dart:io';

import 'speed_provider_http_session_logger.dart';
import 'here/span_fetch_session_logger.dart';
import 'speed_alert_log_filesystem.dart';
import 'speed_debug_log_session.dart';
import 'speed_limit_api_request_logger.dart';

/// Selects which on-disk log session (driving vs simulation) is active.
class SpeedDebugLogRouter {
  SpeedDebugLogRouter._();

  static SpeedDebugLogSession activeSession() =>
      SpeedDebugLogSessionHolder.activeSession();

  static bool isSessionActive() => SpeedDebugLogSessionHolder.isSessionActive();

  static Future<void> startSimulationSession() async {
    await _clearLegacyFetchLog(SpeedDebugLogSession.simulation);
    SpeedLimitApiRequestLogger.clearSessionStorage(SpeedDebugLogSession.simulation);
    HereSpanFetchSessionLogger.clearSession();
    SpeedProviderHttpSessionLogger.clearSession();
    SpeedDebugLogSessionHolder.setActive(SpeedDebugLogSession.simulation);
  }

  static void stopSimulationSession() {
    SpeedDebugLogSessionHolder.setActive(SpeedDebugLogSession.none);
  }

  static Future<void> startDrivingSession() async {
    await _clearLegacyFetchLog(SpeedDebugLogSession.driving);
    SpeedLimitApiRequestLogger.clearSessionStorage(SpeedDebugLogSession.driving);
    HereSpanFetchSessionLogger.clearSession();
    SpeedProviderHttpSessionLogger.clearSession();
    SpeedDebugLogSessionHolder.setActive(SpeedDebugLogSession.driving);
  }

  static void stopDrivingSession() {
    SpeedDebugLogSessionHolder.setActive(SpeedDebugLogSession.none);
  }

  static Future<void> _clearLegacyFetchLog(SpeedDebugLogSession session) async {
    final name = switch (session) {
      SpeedDebugLogSession.simulation => 'speed_limit_fetch_log_simulation.csv',
      SpeedDebugLogSession.driving => 'speed_limit_fetch_log_driving.csv',
      SpeedDebugLogSession.none => throw StateError('invalid session'),
    };
    final f = File('${SpeedAlertLogFilesystem.root.path}/$name');
    if (f.existsSync()) f.deleteSync();
  }
}
