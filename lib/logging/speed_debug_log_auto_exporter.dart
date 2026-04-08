import 'dart:io';

import 'logging_globals.dart';
import 'speed_debug_log_router.dart';
import 'speed_debug_log_session.dart';
import 'speed_fetch_debug_logger.dart';

/// Copies finished simulation / driving logs to Downloads when auto-export is enabled.
class SpeedDebugLogAutoExporter {
  SpeedDebugLogAutoExporter._();

  static Future<void> exportSimulationSessionEndIfEnabled() async {
    try {
      final prefs = speedAlertLoggingPreferences;
      if (prefs != null && Platform.isAndroid) {
        await SpeedFetchDebugLogger.copySessionLogToPublicDownloads(
          SpeedDebugLogSession.simulation,
        );
      }
    } finally {
      SpeedDebugLogRouter.stopSimulationSession();
    }
  }

  static Future<void> exportDrivingSessionEndIfEnabled() async {
    try {
      final prefs = speedAlertLoggingPreferences;
      if (prefs != null && Platform.isAndroid) {
        await SpeedFetchDebugLogger.copySessionLogToPublicDownloads(
          SpeedDebugLogSession.driving,
        );
      }
    } finally {
      SpeedDebugLogRouter.stopDrivingSession();
    }
  }
}
