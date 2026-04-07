import 'dart:io';

import '../services/preferences_manager.dart';
import 'here_fetch_telemetry.dart';
import 'speed_alert_log_filesystem.dart';
import 'speed_provider_http_session_logger.dart';
import 'here_span_fetch_session_logger.dart';
import 'speed_debug_log_session.dart';
import 'speed_limit_api_request_logger.dart';

export 'here_fetch_telemetry.dart';

/// Append structured speed-fetch debug rows (CSV) for the active session.
class SpeedFetchDebugLogger {
  SpeedFetchDebugLogger._();

  static String utcNow() => SpeedLimitApiRequestLogger.utcNow();

  static Future<void> clearSessionStorage(SpeedDebugLogSession session) async {
    if (session == SpeedDebugLogSession.none) return;
    final legacy = switch (session) {
      SpeedDebugLogSession.simulation => 'speed_limit_fetch_log_simulation.csv',
      SpeedDebugLogSession.driving => 'speed_limit_fetch_log_driving.csv',
      SpeedDebugLogSession.none => '',
    };
    final f = File('${SpeedAlertLogFilesystem.root.path}/$legacy');
    if (f.existsSync()) f.deleteSync();
  }

  static Future<void> append({
    required PreferencesManager preferencesManager,
    required double lat,
    required double lng,
    double? bearing,
    required int rawMph,
    required int displayMph,
    String? segmentKey,
    required String sourceTag,
    int? tomtomMph,
    int? mapboxMph,
    HereFetchTelemetry? hereTelemetry,
    double? vehicleSpeedMph,
    double? metersSincePriorFetchTrigger,
    int? msSincePriorFetchTrigger,
    int? fetchGeneration,
    int? gpsTracePointCount,
    String mirrorEventType = 'speed_fetch_summary',
    String mirrorCategory = 'speed_limit_fetch_cycle',
    String requestReasonHuman = '',
  }) async {
    final session = SpeedDebugLogSessionHolder.activeSession();
    if (session == SpeedDebugLogSession.none) return;
    if (!preferencesManager.logSpeedFetchesToFile) return;
    final now = utcNow();
    final stabilizedFlag = rawMph != displayMph;
    await SpeedLimitApiRequestLogger.appendSpeedFetchMirror(
      preferencesManager: preferencesManager,
      eventType: mirrorEventType,
      category: mirrorCategory,
      utcRow: now,
      lat: lat,
      lng: lng,
      bearing: bearing,
      rawMph: rawMph,
      displayMph: displayMph,
      stabilized: stabilizedFlag,
      sourceTag: sourceTag,
      segmentKey: segmentKey,
      tomtomMph: tomtomMph,
      mapboxMph: mapboxMph,
      hereTelemetry: hereTelemetry,
      vehicleSpeedMph: vehicleSpeedMph,
      metersSincePriorFetch: metersSincePriorFetchTrigger,
      msSincePriorFetch: msSincePriorFetchTrigger,
      gpsTracePointCount: gpsTracePointCount,
      fetchGeneration: fetchGeneration,
      requestReasonHuman: requestReasonHuman,
      markHereLimitsFromNetworkFetch: mirrorEventType == 'speed_fetch_summary',
    );
  }

  static Future<void> appendHereApiFailure({
    required PreferencesManager preferencesManager,
    required double lat,
    required double lng,
    double? bearing,
    required String sourceTag,
    required HereFetchTelemetry hereTelemetry,
    int rawMph = -1,
    int displayMph = -1,
    double? vehicleSpeedMph,
    double? metersSincePriorFetchTrigger,
    int? msSincePriorFetchTrigger,
    int? fetchGeneration,
    int? gpsTracePointCount,
    String requestReasonHuman =
        'HERE alert fetch failed with an exception before a complete response.',
  }) async {
    await append(
      preferencesManager: preferencesManager,
      lat: lat,
      lng: lng,
      bearing: bearing,
      rawMph: rawMph,
      displayMph: displayMph,
      segmentKey: null,
      sourceTag: sourceTag,
      tomtomMph: null,
      mapboxMph: null,
      hereTelemetry: hereTelemetry,
      vehicleSpeedMph: vehicleSpeedMph,
      metersSincePriorFetchTrigger: metersSincePriorFetchTrigger,
      msSincePriorFetchTrigger: msSincePriorFetchTrigger,
      fetchGeneration: fetchGeneration,
      gpsTracePointCount: gpsTracePointCount,
      mirrorEventType: 'speed_fetch_failure',
      mirrorCategory: 'here_alert_fetch_failure',
      requestReasonHuman: requestReasonHuman,
    );
  }

  static Future<String?> copySessionLogToPublicDownloads(
    SpeedDebugLogSession session,
  ) async {
    final csvName = await SpeedLimitApiRequestLogger.copySessionRequestsToPublicDownloads(session);
    await HereSpanFetchSessionLogger.copySessionToPublicDownloads(session);
    await SpeedProviderHttpSessionLogger.copyTomTomToPublicDownloads(session);
    await SpeedProviderHttpSessionLogger.copyMapboxToPublicDownloads(session);
    return csvName;
  }
}
