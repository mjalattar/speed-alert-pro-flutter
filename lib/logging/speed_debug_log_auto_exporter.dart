import 'dart:io';

import 'logging_globals.dart';
import 'speed_debug_log_router.dart';
import 'speed_debug_log_session.dart';
import 'speed_fetch_debug_logger.dart';

/// Copies finished simulation logs to Downloads when auto-export is enabled.
class SpeedDebugLogAutoExporter {
  SpeedDebugLogAutoExporter._();

  static Future<void> exportSimulationSessionEndIfEnabled() async {
    final prefs = speedAlertLoggingPreferences;
    if (prefs == null) return;
    try {
      if (Platform.isAndroid && prefs.logSpeedFetchesToFile) {
        await SpeedFetchDebugLogger.copySessionLogToPublicDownloads(
          SpeedDebugLogSession.simulation,
        );
      }
    } finally {
      SpeedDebugLogRouter.stopSimulationSession();
    }
  }
}
