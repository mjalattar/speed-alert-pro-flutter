import 'dart:io';

import '../config/app_config.dart';
import '../engine/annotation_section_speed_model.dart';
import '../models/speed_limit_data.dart';
import '../services/preferences_manager.dart';
import 'csv_formatting.dart';
import 'here_fetch_telemetry.dart';
import 'speed_alert_log_filesystem.dart';
import 'speed_debug_log_session.dart';
import 'speed_limit_logging_context.dart';
import 'log_export_platform.dart';

/// Kotlin [SpeedLimitApiRequestLogger].
class SpeedLimitApiRequestLogger {
  SpeedLimitApiRequestLogger._();

  static final Object _lock = Object();
  static String _lastCompareCacheEventSignature = '';

  static const String _csvHeader =
      'utc_time,event_type,category,method,url_redacted,http_code,note,'
      'lat,lng,bearing_deg,speed_mps,horizontal_accuracy_m,altitude_m,vertical_accuracy_m,'
      'location_provider,location_fix_age_ms,'
      'vehicle_speed_mph,'
      'raw_mph,display_mph,here_compare_mph,tomtom_mph,mapbox_mph,stabilized,source_tag,segment_key,'
      'here_api_request_utc,here_api_response_utc,here_response_source,here_response_confidence,'
      'here_functional_class,here_segment_cache_zones,here_segment_route_len_m,here_api_error,'
      'meters_since_prior_fetch_trigger,ms_since_prior_fetch_trigger,gps_trace_point_count,'
      'request_reason_human,road_functional_class,odometer_meters,'
      'build_use_remote_here,prefs_use_remote_speed_api,prefs_here_enabled,prefs_local_stabilizer,'
      'here_alert_path,fetch_generation,app_session_id,compare_fetch_diag\n';

  static String utcNow() => SpeedFetchDebugLoggerUtc.utcNow();

  static void clearSessionStorage(SpeedDebugLogSession session) {
    if (session == SpeedDebugLogSession.none) return;
    synchronized(_lock, () {
      _lastCompareCacheEventSignature = '';
      final f = SpeedAlertLogFilesystem.sessionLogFile(session);
      if (f.existsSync()) f.deleteSync();
      final legacyName = switch (session) {
        SpeedDebugLogSession.simulation => 'speed_limit_api_requests_simulation.csv',
        SpeedDebugLogSession.driving => 'speed_limit_api_requests_driving.csv',
        SpeedDebugLogSession.none => '',
      };
      if (legacyName.isNotEmpty) {
        final leg = File('${SpeedAlertLogFilesystem.root.path}/$legacyName');
        if (leg.existsSync()) leg.deleteSync();
      }
    });
  }

  static void synchronized(Object lock, void Function() fn) {
    // Dart single-threaded; lock object documents intent for future isolates.
    fn();
  }

  static Future<void> appendIfEnabled({
    required PreferencesManager preferencesManager,
    required String category,
    required String method,
    required String urlRedacted,
    required int httpCode,
    String note = '',
    String requestReasonHuman = '',
  }) async {
    if (!preferencesManager.logSpeedFetchesToFile) return;
    await append(
      preferencesManager: preferencesManager,
      category: category,
      method: method,
      urlRedacted: urlRedacted,
      httpCode: httpCode,
      note: note,
      requestReasonHuman: requestReasonHuman,
    );
  }

  static bool isLoggingEnabled(PreferencesManager preferencesManager) =>
      preferencesManager.logSpeedFetchesToFile;

  static Future<void> append({
    required PreferencesManager preferencesManager,
    required String category,
    required String method,
    required String urlRedacted,
    required int httpCode,
    String note = '',
    String requestReasonHuman = '',
  }) async {
    if (!isLoggingEnabled(preferencesManager)) return;
    if (!SpeedDebugLogSessionHolder.isSessionActive()) return;
    final reason = requestReasonHuman.isNotEmpty
        ? requestReasonHuman
        : _defaultHttpRequestReason(category, method);
    final snap = await SpeedLimitLoggingContext.snapshotAsync();
    _writeRow(
      preferencesManager: preferencesManager,
      utc: utcNow(),
      eventType: 'http',
      category: category,
      method: method,
      urlRedacted: urlRedacted,
      httpCode: httpCode,
      note: note,
      requestReasonHuman: reason,
      snap: snap,
      vehicleSpeedMph: '',
      rawMph: '',
      displayMph: '',
      hereCompareMph: SpeedLimitLoggingContext.hereCompareMphForCsv(),
      stabilized: '',
      sourceTag: '',
      segmentKey: '',
      tomtomMph: SpeedLimitLoggingContext.compareTomTomMphForCsv(),
      mapboxMph: SpeedLimitLoggingContext.compareMapboxMphForCsv(),
      hereReqUtc: '',
      hereResUtc: '',
      hereSrc: '',
      hereConf: '',
      hereFc: '',
      hereZones: '',
      hereRouteLen: '',
      hereErr: '',
      metersSinceFetch: '',
      msSinceFetch: '',
      gpsTracePoints: '',
      fetchGeneration: '',
      compareFetchDiag: '',
    );
  }

  static String _defaultHttpRequestReason(String category, String method) {
    return switch (category) {
      'HERE_Routing' =>
        'HERE Maps REST ($method): routing or speed-limit span request from the app.',
      'TomTom' =>
        'TomTom REST ($method): snap-to-roads for speed compare (polyline model).',
      'Mapbox' =>
        'Mapbox REST ($method): directions with maxspeed annotation for speed compare.',
      'Supabase_here-speed' =>
        'Supabase Edge here-speed ($method): server-side HERE / multi-provider speed.',
      _ => 'Speed-related HTTP $method (category=$category).',
    };
  }

  static Future<void> appendSpeedFetchMirror({
    required PreferencesManager preferencesManager,
    required String eventType,
    required String category,
    required String utcRow,
    required double lat,
    required double lng,
    double? bearing,
    required int rawMph,
    required int displayMph,
    required bool stabilized,
    required String sourceTag,
    String? segmentKey,
    int? tomtomMph,
    int? mapboxMph,
    HereFetchTelemetry? hereTelemetry,
    double? vehicleSpeedMph,
    double? metersSincePriorFetch,
    int? msSincePriorFetch,
    int? gpsTracePointCount,
    int? fetchGeneration,
    String requestReasonHuman = '',
    bool markHereLimitsFromNetworkFetch = false,
  }) async {
    if (!isLoggingEnabled(preferencesManager)) return;
    if (!SpeedDebugLogSessionHolder.isSessionActive()) return;
    final snap = await SpeedLimitLoggingContext.snapshotAsync();
    final bearStr = bearing != null && bearing.isFinite ? bearing.toStringAsFixed(1) : '';
    final seg = segmentKey?.replaceAll(',', ';') ?? '';
    final ht = hereTelemetry;
    final boldHere =
        markHereLimitsFromNetworkFetch && rawMph >= 0 && displayMph >= 0;
    final rawStr = boldHere
        ? SpeedLimitLoggingContext.formatMphCsvCell(rawMph, true)
        : rawMph.toString();
    final displayStr = boldHere
        ? SpeedLimitLoggingContext.formatMphCsvCell(displayMph, true)
        : displayMph.toString();
    final hereCompareStr = boldHere
        ? SpeedLimitLoggingContext.formatMphCsvCell(rawMph, true)
        : SpeedLimitLoggingContext.hereCompareMphForCsv();
    final ttStr = tomtomMph != null
        ? tomtomMph.toString()
        : SpeedLimitLoggingContext.compareTomTomMphForCsv();
    final mbStr = mapboxMph != null
        ? mapboxMph.toString()
        : SpeedLimitLoggingContext.compareMapboxMphForCsv();
    final roadFc = ht?.functionalClass != null
        ? SpeedLimitLoggingContext.functionalClassHumanLabel(ht!.functionalClass!)
        : snap.roadFunctionalClass;
    final rowSnap = LoggingSnapshot(
      hasFix: true,
      lat: lat,
      lng: lng,
      bearingDeg: bearStr,
      speedMps: snap.speedMps,
      horizontalAccuracyM: snap.horizontalAccuracyM,
      altitudeM: snap.altitudeM,
      verticalAccuracyM: snap.verticalAccuracyM,
      provider: snap.provider,
      fixAgeMs: snap.fixAgeMs,
      roadFunctionalClass: roadFc,
      odometerMeters: snap.odometerMeters,
    );
    _writeRow(
      preferencesManager: preferencesManager,
      utc: utcRow,
      eventType: eventType,
      category: category,
      method: '',
      urlRedacted: '',
      httpCode: -1,
      note: '',
      requestReasonHuman: requestReasonHuman,
      snap: rowSnap,
      vehicleSpeedMph:
          vehicleSpeedMph != null && vehicleSpeedMph.isFinite ? vehicleSpeedMph.toStringAsFixed(2) : '',
      rawMph: rawStr,
      displayMph: displayStr,
      hereCompareMph: hereCompareStr,
      stabilized: stabilized ? '1' : '0',
      sourceTag: sourceTag,
      segmentKey: seg,
      tomtomMph: ttStr,
      mapboxMph: mbStr,
      hereReqUtc: ht?.requestUtc ?? '',
      hereResUtc: ht?.responseUtc ?? '',
      hereSrc: ht?.responseSource ?? '',
      hereConf: ht?.responseConfidence ?? '',
      hereFc: ht?.functionalClass?.toString() ?? '',
      hereZones: ht?.segmentCacheZoneCount?.toString() ?? '',
      hereRouteLen: ht?.segmentCacheRouteLenM != null
          ? ht!.segmentCacheRouteLenM!.toStringAsFixed(1)
          : '',
      hereErr: ht?.apiError ?? '',
      metersSinceFetch: metersSincePriorFetch != null && metersSincePriorFetch.isFinite
          ? metersSincePriorFetch.toStringAsFixed(1)
          : '',
      msSinceFetch: msSincePriorFetch?.toString() ?? '',
      gpsTracePoints: gpsTracePointCount?.toString() ?? '',
      fetchGeneration: fetchGeneration?.toString() ?? '',
      compareFetchDiag: '',
    );
  }

  /// One row per TomTom or Mapbox compare HTTP response: anchor vs slice, snap/edge projection, lead waypoint.
  static Future<void> appendCompareFetchDiagnostics({
    required PreferencesManager preferencesManager,
    required String provider,
    required double vehicleLat,
    required double vehicleLng,
    double? bearingDeg,
    required double alongMeters,
    required String leadDestLatLng,
    required int? reportedMph,
    required int? sliceMph,
    TomTomSnapVehicleProjection? tomTomProjection,
    MapboxVehicleEdgeProjection? mapboxEdge,
  }) async {
    if (!isLoggingEnabled(preferencesManager)) return;
    if (!SpeedDebugLogSessionHolder.isSessionActive()) return;
    final snap = await SpeedLimitLoggingContext.snapshotAsync();
    final bearStr =
        bearingDeg != null && bearingDeg.isFinite ? bearingDeg.toStringAsFixed(1) : '';
    final rowSnap = LoggingSnapshot(
      hasFix: true,
      lat: vehicleLat,
      lng: vehicleLng,
      bearingDeg: bearStr,
      speedMps: snap.speedMps,
      horizontalAccuracyM: snap.horizontalAccuracyM,
      altitudeM: snap.altitudeM,
      verticalAccuracyM: snap.verticalAccuracyM,
      provider: snap.provider,
      fixAgeMs: snap.fixAgeMs,
      roadFunctionalClass: snap.roadFunctionalClass,
      odometerMeters: snap.odometerMeters,
    );
    final buf = StringBuffer(provider)
      ..write('|along_m=${alongMeters.toStringAsFixed(1)}')
      ..write('|lead=$leadDestLatLng')
      ..write('|reported_mph=${reportedMph ?? ''}')
      ..write('|slice_mph=${sliceMph ?? ''}');
    if (tomTomProjection != null) {
      buf
        ..write('|snap_ri=${tomTomProjection.routeIndex}')
        ..write('|snap_lat=${tomTomProjection.snapLat.toStringAsFixed(7)}')
        ..write('|snap_lng=${tomTomProjection.snapLng.toStringAsFixed(7)}')
        ..write('|snap_dist_m=${tomTomProjection.snapDistanceM.toStringAsFixed(1)}');
    }
    if (mapboxEdge != null) {
      buf
        ..write('|edge_idx=${mapboxEdge.edgeIndex}')
        ..write('|edge_mph=${mapboxEdge.edgeMph ?? ''}');
    }
    _writeRow(
      preferencesManager: preferencesManager,
      utc: utcNow(),
      eventType: 'compare_fetch_diag',
      category: 'compare_providers',
      method: '',
      urlRedacted: '',
      httpCode: -1,
      note: 'Compare provider fetch diagnostics (see compare_fetch_diag column).',
      requestReasonHuman:
          'TomTom/Mapbox: along-polyline slice vs vehicle anchor; snap/edge indices; lead waypoint.',
      snap: rowSnap,
      vehicleSpeedMph: '',
      rawMph: '',
      displayMph: '',
      hereCompareMph: SpeedLimitLoggingContext.hereCompareMphForCsv(),
      stabilized: '',
      sourceTag: 'compare_fetch_diag',
      segmentKey: '',
      tomtomMph: SpeedLimitLoggingContext.compareTomTomMphForCsv(),
      mapboxMph: SpeedLimitLoggingContext.compareMapboxMphForCsv(),
      hereReqUtc: '',
      hereResUtc: '',
      hereSrc: '',
      hereConf: '',
      hereFc: '',
      hereZones: '',
      hereRouteLen: '',
      hereErr: '',
      metersSinceFetch: '',
      msSinceFetch: '',
      gpsTracePoints: '',
      fetchGeneration: '',
      compareFetchDiag: buf.toString(),
    );
  }

  static Future<void> appendCompareCacheUpdate({
    required PreferencesManager preferencesManager,
    required String trigger,
    SpeedLimitData? tomtomData,
    SpeedLimitData? mapboxData,
  }) async {
    if (!preferencesManager.isTomTomApiEnabled &&
        !preferencesManager.isMapboxApiEnabled) {
      return;
    }
    if (!isLoggingEnabled(preferencesManager)) return;
    if (!SpeedDebugLogSessionHolder.isSessionActive()) return;
    final sig =
        '$trigger|${tomtomData?.speedLimitMph}|${mapboxData?.speedLimitMph}|${tomtomData?.source}|${mapboxData?.source}';
    if (sig == _lastCompareCacheEventSignature) return;
    _lastCompareCacheEventSignature = sig;

    String clip(String s, int max) => s.length <= max ? s : s.substring(0, max);
    final snap = await SpeedLimitLoggingContext.snapshotAsync();
    final ttM = tomtomData?.speedLimitMph;
    final mbM = mapboxData?.speedLimitMph;
    final ttCell = SpeedLimitLoggingContext.formatMphCsvCell(ttM, trigger == 'tomtom_fetch');
    final mbCell = SpeedLimitLoggingContext.formatMphCsvCell(mbM, trigger == 'mapbox_fetch');
    final note = StringBuffer()
      ..write('trigger=$trigger tomtom_mph=${ttM ?? ''} mapbox_mph=${mbM ?? ''}');
    final ts = tomtomData != null ? tomtomData.source.trim() : '';
    if (ts.isNotEmpty) {
      note.write(' tomtom_src=${clip(ts.replaceAll('\n', ' '), 120)}');
    }
    final ms = mapboxData != null ? mapboxData.source.trim() : '';
    if (ms.isNotEmpty) {
      note.write(' mapbox_src=${clip(ms.replaceAll('\n', ' '), 120)}');
    }
    _writeRow(
      preferencesManager: preferencesManager,
      utc: utcNow(),
      eventType: 'compare_cache_update',
      category: 'compare_providers',
      method: '',
      urlRedacted: '',
      httpCode: -1,
      note: note.toString(),
      requestReasonHuman:
          'TomTom/Mapbox compare cache updated (see note for mph and API source strings).',
      snap: snap,
      vehicleSpeedMph: '',
      rawMph: '',
      displayMph: '',
      hereCompareMph: SpeedLimitLoggingContext.hereCompareMphForCsv(),
      stabilized: '',
      sourceTag: 'compare_cache',
      segmentKey: '',
      tomtomMph: ttCell,
      mapboxMph: mbCell,
      hereReqUtc: '',
      hereResUtc: '',
      hereSrc: '',
      hereConf: '',
      hereFc: '',
      hereZones: '',
      hereRouteLen: '',
      hereErr: '',
      metersSinceFetch: '',
      msSinceFetch: '',
      gpsTracePoints: '',
      fetchGeneration: '',
      compareFetchDiag: '',
    );
  }

  static Future<void> appendDisplayLimitChange({
    required PreferencesManager preferencesManager,
    required double lat,
    required double lng,
    double? bearing,
    required double vehicleMph,
    required int stabilizerMph,
    required int newDisplayMph,
    int? previousDisplayMph,
    String? segmentKey,
    required bool sharpHeadingInvalidate,
  }) async {
    if (!isLoggingEnabled(preferencesManager)) return;
    if (!SpeedDebugLogSessionHolder.isSessionActive()) return;
    final snap = await SpeedLimitLoggingContext.snapshotAsync();
    final bearStr = bearing != null && bearing.isFinite ? bearing.toStringAsFixed(1) : '';
    final seg = segmentKey?.replaceAll(',', ';') ?? '';
    final prevStr = previousDisplayMph?.toString() ?? '';
    final note =
        'prev_display_mph=$prevStr new_display_mph=$newDisplayMph stabilizer_mph=$stabilizerMph '
        'heading_invalidate=${sharpHeadingInvalidate ? '1' : '0'}';
    final rowSnap = LoggingSnapshot(
      hasFix: true,
      lat: lat,
      lng: lng,
      bearingDeg: bearStr,
      speedMps: snap.speedMps,
      horizontalAccuracyM: snap.horizontalAccuracyM,
      altitudeM: snap.altitudeM,
      verticalAccuracyM: snap.verticalAccuracyM,
      provider: snap.provider,
      fixAgeMs: snap.fixAgeMs,
      roadFunctionalClass: snap.roadFunctionalClass,
      odometerMeters: snap.odometerMeters,
    );
    _writeRow(
      preferencesManager: preferencesManager,
      utc: utcNow(),
      eventType: 'display_limit_change',
      category: 'speed_display',
      method: '',
      urlRedacted: '',
      httpCode: -1,
      note: note,
      requestReasonHuman:
          'Shown speed limit changed (after stabilizer and downward debouncer).',
      snap: rowSnap,
      vehicleSpeedMph: vehicleMph.toStringAsFixed(2),
      rawMph: stabilizerMph.toString(),
      displayMph: newDisplayMph.toString(),
      hereCompareMph: SpeedLimitLoggingContext.hereCompareMphForCsv(),
      stabilized: stabilizerMph != newDisplayMph ? '1' : '0',
      sourceTag: 'ui_display',
      segmentKey: seg,
      tomtomMph: SpeedLimitLoggingContext.compareTomTomMphForCsv(),
      mapboxMph: SpeedLimitLoggingContext.compareMapboxMphForCsv(),
      hereReqUtc: '',
      hereResUtc: '',
      hereSrc: '',
      hereConf: '',
      hereFc: '',
      hereZones: '',
      hereRouteLen: '',
      hereErr: '',
      metersSinceFetch: '',
      msSinceFetch: '',
      gpsTracePoints: '',
      fetchGeneration: '',
      compareFetchDiag: '',
    );
  }

  static void _writeRow({
    required PreferencesManager preferencesManager,
    required String utc,
    required String eventType,
    required String category,
    required String method,
    required String urlRedacted,
    required int httpCode,
    required String note,
    required String requestReasonHuman,
    required LoggingSnapshot snap,
    required String vehicleSpeedMph,
    required String rawMph,
    required String displayMph,
    required String hereCompareMph,
    required String stabilized,
    required String sourceTag,
    required String segmentKey,
    required String tomtomMph,
    required String mapboxMph,
    required String hereReqUtc,
    required String hereResUtc,
    required String hereSrc,
    required String hereConf,
    required String hereFc,
    required String hereZones,
    required String hereRouteLen,
    required String hereErr,
    required String metersSinceFetch,
    required String msSinceFetch,
    required String gpsTracePoints,
    required String fetchGeneration,
    String compareFetchDiag = '',
  }) {
    if (!SpeedDebugLogSessionHolder.isSessionActive()) return;
    final session = SpeedDebugLogSessionHolder.activeSession();
    final latStr = snap.hasFix ? snap.lat.toStringAsFixed(7) : '';
    final lngStr = snap.hasFix ? snap.lng.toStringAsFixed(7) : '';
    final line = StringBuffer()
      ..write('${CsvFormatting.escape(utc)},')
      ..write('${CsvFormatting.escape(eventType)},')
      ..write('${CsvFormatting.escape(category)},')
      ..write('${CsvFormatting.escape(method)},')
      ..write('${CsvFormatting.escape(urlRedacted)},')
      ..write('$httpCode,')
      ..write('${CsvFormatting.escape(note.replaceAll('\n', ' ').length > 500 ? note.replaceAll('\n', ' ').substring(0, 500) : note.replaceAll('\n', ' '))},')
      ..write('${CsvFormatting.escape(latStr)},')
      ..write('${CsvFormatting.escape(lngStr)},')
      ..write('${CsvFormatting.escape(snap.bearingDeg)},')
      ..write('${CsvFormatting.escape(snap.speedMps)},')
      ..write('${CsvFormatting.escape(snap.horizontalAccuracyM)},')
      ..write('${CsvFormatting.escape(snap.altitudeM)},')
      ..write('${CsvFormatting.escape(snap.verticalAccuracyM)},')
      ..write('${CsvFormatting.escape(snap.provider)},')
      ..write('${CsvFormatting.escape(snap.fixAgeMs)},')
      ..write('${CsvFormatting.escape(vehicleSpeedMph)},')
      ..write('${CsvFormatting.escape(rawMph)},')
      ..write('${CsvFormatting.escape(displayMph)},')
      ..write('${CsvFormatting.escape(hereCompareMph)},')
      ..write('${CsvFormatting.escape(tomtomMph)},')
      ..write('${CsvFormatting.escape(mapboxMph)},')
      ..write('${CsvFormatting.escape(stabilized)},')
      ..write('${CsvFormatting.escape(sourceTag)},')
      ..write('${CsvFormatting.escape(segmentKey)},')
      ..write('${CsvFormatting.escape(hereReqUtc)},')
      ..write('${CsvFormatting.escape(hereResUtc)},')
      ..write('${CsvFormatting.escape(hereSrc)},')
      ..write('${CsvFormatting.escape(hereConf)},')
      ..write('${CsvFormatting.escape(hereFc)},')
      ..write('${CsvFormatting.escape(hereZones)},')
      ..write('${CsvFormatting.escape(hereRouteLen)},')
      ..write('${CsvFormatting.escape(hereErr)},')
      ..write('${CsvFormatting.escape(metersSinceFetch)},')
      ..write('${CsvFormatting.escape(msSinceFetch)},')
      ..write('${CsvFormatting.escape(gpsTracePoints)},')
      ..write('${CsvFormatting.escape(requestReasonHuman.replaceAll('\n', ' ').length > 800 ? requestReasonHuman.replaceAll('\n', ' ').substring(0, 800) : requestReasonHuman.replaceAll('\n', ' '))},')
      ..write('${CsvFormatting.escape(snap.roadFunctionalClass)},')
      ..write('${CsvFormatting.escape(snap.odometerMeters)},')
      ..write('${AppConfig.useRemoteHere ? '1' : '0'},')
      ..write('${preferencesManager.useRemoteSpeedApi ? '1' : '0'},')
      ..write('${preferencesManager.isHereApiEnabled ? '1' : '0'},')
      ..write('${preferencesManager.useLocalSpeedStabilizer ? '1' : '0'},')
      ..write('${CsvFormatting.escape(SpeedLimitLoggingContext.hereAlertPathForCsv())},')
      ..write('${CsvFormatting.escape(fetchGeneration)},')
      ..write('${CsvFormatting.escape(SpeedLimitLoggingContext.appSessionId)},')
      ..write('${CsvFormatting.escape(compareFetchDiag)}\n');
    final file = SpeedAlertLogFilesystem.sessionLogFile(session);
    final needHeader = !file.existsSync() || file.lengthSync() == 0;
    final raf = file.openSync(mode: FileMode.append);
    try {
      if (needHeader) {
        raf.writeStringSync(_csvHeader);
      }
      raf.writeStringSync(line.toString());
    } finally {
      raf.closeSync();
    }
  }

  static final RegExp _redactUrlRe = RegExp(
    r'([?&])(apiKey|apikey|key|access_token)=([^&]*)',
    caseSensitive: false,
  );

  static String redactUrl(String url) {
    return url.replaceAllMapped(_redactUrlRe, (m) {
      return '${m[1]}${m[2]}=[REDACTED]';
    });
  }

  /// Kotlin [copySessionRequestsToPublicDownloads] — Android uses MediaStore via platform channel.
  static Future<String?> copySessionRequestsToPublicDownloads(
    SpeedDebugLogSession session,
  ) async {
    if (session == SpeedDebugLogSession.none) return null;
    final source = SpeedAlertLogFilesystem.sessionLogFile(session);
    if (!source.existsSync() || source.lengthSync() == 0) return null;
    return LogExportPlatform.copyUnifiedCsvToDownloads(
      sourcePath: source.path,
      session: session,
    );
  }
}

/// Shared UTC formatter for loggers (Kotlin [SpeedFetchDebugLogger.utcNow]).
class SpeedFetchDebugLoggerUtc {
  SpeedFetchDebugLoggerUtc._();

  static String utcNow() {
    final n = DateTime.now().toUtc();
    String t(int v) => v.toString().padLeft(2, '0');
    String ms(int v) => v.toString().padLeft(3, '0');
    return '${n.year}-${t(n.month)}-${t(n.day)}T${t(n.hour)}:${t(n.minute)}:${t(n.second)}.${ms(n.millisecond)}Z';
  }
}
