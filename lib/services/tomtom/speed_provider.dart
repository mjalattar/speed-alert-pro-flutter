// TomTom Snap to Roads — speed limit provider (primary or secondary).

import 'dart:async';
import 'dart:developer' as developer;

import '../../config/app_config.dart';
import '../../core/android_location_compat.dart';
import '../../core/geo.dart';
import '../../core/speed_provider_constants.dart';
import '../../engine/compare/compare_section_speed_model.dart';
import '../../engine/tomtom/cross_track_geometry.dart';
import '../../logging/speed_limit_api_request_logger.dart';
import '../../logging/speed_limit_logging_context.dart';
import '../../logging/speed_limit_http_log_interceptor.dart';
import '../../models/speed_limit_data.dart';
import '../preferences_manager.dart';
import '../speed_providers/route_fetch_models.dart';
import '../speed_providers/route_lead_geometry.dart';

void _logD(String message) {
  developer.log(message, name: 'TomTomSpeed');
}

void _logE(String message, Object e, StackTrace st) {
  developer.log(message, name: 'TomTomSpeed', error: e, stackTrace: st);
}

String _httpErrorSnippet(String body, [int maxChars = 400]) {
  if (body.length <= maxChars) return body;
  return '${body.substring(0, maxChars)}…';
}

/// TomTom Snap to Roads: HTTP fetch, sticky cache, along-polyline resolution.
class TomTomSpeedProvider {
  TomTomSpeedProvider({
    required this.preferencesManager,
    this.onSliceChanged,
  });

  final PreferencesManager preferencesManager;

  /// Called after cache mutation with trigger (`tomtom_fetch`, `tomtom_along`, `tomtom_clear`).
  void Function(String trigger)? onSliceChanged;

  static const Duration _httpTimeout = Duration(seconds: 30);

  static const Map<String, String> _httpHeaders = {
    'Accept': 'application/json',
    'User-Agent': 'SpeedAlertPro/1.0',
  };

  SpeedLimitData? _cachedLimit;

  void clearStickyCacheOnly() {
    _cachedLimit = null;
    _emitTomTomCacheLogging('tomtom_clear');
    onSliceChanged?.call('tomtom_clear');
  }

  SpeedLimitData? peekCached() => _cachedLimit;

  void publishFromAlong(SpeedLimitData data) {
    _cachedLimit = data;
    _emitTomTomCacheLogging('tomtom_along');
    onSliceChanged?.call('tomtom_along');
  }

  void _emitTomTomCacheLogging(String trigger) {
    final mph = _cachedLimit?.speedLimitMph;
    SpeedLimitLoggingContext.setTomTomMphCell(trigger, mph);
    unawaited(
      SpeedLimitApiRequestLogger.appendTomTomStickyCacheLog(
        preferencesManager: preferencesManager,
        trigger: trigger,
        tomtomData: _cachedLimit,
      ),
    );
  }

  Future<RouteFetchOutcome> fetchSpeedLimit({
    required double latitude,
    required double longitude,
    double? headingDegrees,
    int? locationFixTimeUtcMs,
    double? speedMpsForSnapTiming,
    TomTomPolylineMatchingOptions? polylineMatchingOptions,
  }) async {
    if (!preferencesManager.isTomTomApiEnabled) {
      return RouteFetchOutcome(_disabledProviderData(), null);
    }
    final key = AppConfig.tomtomApiKey.trim();
    if (key.isEmpty) {
      return RouteFetchOutcome(
        const SpeedLimitData(
          provider: 'TomTom',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'API key not configured',
        ),
        null,
      );
    }
    try {
      final routeJson = await _fetchSnapRouteJson(
        latitude,
        longitude,
        headingDegrees,
        locationFixTimeUtcMs,
        speedMpsForSnapTiming,
      );
      final model = routeJson != null
          ? AnnotationSectionSpeedModel.fromTomTomSnapRouteJson(
              routeJson,
              vehicleLat: latitude,
              vehicleLng: longitude,
              headingDegrees: headingDegrees,
            )
          : null;
      if (model != null) {
        final matchOpts =
            polylineMatchingOptions?.withEdgeMph(model.mphHintsPerEdge());
        final along = TomTomCrossTrackGeometry.alongPolylineMetersForMatching(
          latitude,
          longitude,
          model.geometry,
          headingDegrees,
          matchingOptions: matchOpts,
        );
        final data = model.speedLimitDataAtAlong(along);
        _recordLimit(data);
        if (routeJson != null) {
          _maybeLogFetch(
            routeJson: routeJson,
            latitude: latitude,
            longitude: longitude,
            headingDegrees: headingDegrees,
            along: along,
            data: data,
            model: model,
          );
        }
        return RouteFetchOutcome(data, model);
      }
      const data = SpeedLimitData(
        provider: 'TomTom',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source:
            'TomTom: no route model from snap',
      );
      _recordLimit(data);
      return RouteFetchOutcome(data, null);
    } catch (e, st) {
      final errorMsg = '$e';
      _logE('TomTom API error: $errorMsg', e, st);
      final data = SpeedLimitData(
        provider: 'TomTom',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'TomTom API - Error: $errorMsg',
      );
      _recordLimit(data);
      return RouteFetchOutcome(data, null);
    }
  }

  SpeedLimitData _disabledProviderData() => const SpeedLimitData(
        provider: 'TomTom',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Disabled in settings',
      );

  void _recordLimit(SpeedLimitData data) {
    _cachedLimit = data;
    _emitTomTomCacheLogging('tomtom_fetch');
    onSliceChanged?.call('tomtom_fetch');
  }

  void _maybeLogFetch({
    required String routeJson,
    required double latitude,
    required double longitude,
    required double? headingDegrees,
    required double along,
    required SpeedLimitData data,
    required AnnotationSectionSpeedModel model,
  }) {
    if (!SpeedLimitApiRequestLogger.isLoggingEnabled(preferencesManager)) return;
    final lead = routeLeadDestinationForLog(latitude, longitude, headingDegrees);
    final slice = model.sliceOnlyMphAtAlong(along);
    final proj =
        AnnotationSectionSpeedModel.tomTomVehicleProjectionFromSnapJson(
      routeJson,
      latitude,
      longitude,
      headingDegrees: headingDegrees,
    );
    unawaited(
      SpeedLimitApiRequestLogger.appendTomTomFetchDiagnostics(
        preferencesManager: preferencesManager,
        vehicleLat: latitude,
        vehicleLng: longitude,
        bearingDeg: headingDegrees,
        alongMeters: along,
        leadDestLatLng: lead,
        reportedMph: data.speedLimitMph,
        sliceMph: slice,
        tomTomProjection: proj,
      ),
    );
  }

  static double _snapLegDistanceM(
    double lat,
    double lng,
    double destLat,
    double destLng,
  ) {
    final d = AndroidLocationCompat.distanceBetweenMeters(lat, lng, destLat, destLng);
    return d < 5.0 ? 5.0 : d;
  }

  static int _snapCorridorPointCount(double distanceM) {
    final spacing = SpeedProviderConstants.tomtomSnapCorridorPointSpacingM;
    final maxPoints = SpeedProviderConstants.tomtomSnapCorridorMaxPoints;
    final segments = (distanceM / spacing).ceil().clamp(1, 999999);
    return (segments + 1).clamp(2, maxPoints);
  }

  static DateTime _snapStartInstant(int? locationFixTimeUtcMs) {
    if (locationFixTimeUtcMs != null && locationFixTimeUtcMs > 0) {
      return DateTime.fromMillisecondsSinceEpoch(locationFixTimeUtcMs, isUtc: true);
    }
    return DateTime.now().toUtc();
  }

  static int _snapTotalDurationMs(double distM, double? speedMpsHint) {
    var speedMps = (speedMpsHint != null && speedMpsHint >= 1.0)
        ? speedMpsHint.toDouble()
        : 28.0;
    speedMps = speedMps.clamp(6.0, 55.0);
    final dtSec = (distM / speedMps).round().clamp(
      SpeedProviderConstants.tomtomSnapTimestampMinTotalSec,
      SpeedProviderConstants.tomtomSnapTimestampMaxTotalSec,
    );
    return dtSec * 1000;
  }

  Future<String?> _fetchSnapRouteJson(
    double lat,
    double lng,
    double? headingDegrees,
    int? locationFixTimeUtcMs,
    double? speedMpsForSnapTiming,
  ) async {
    final destStr = routeLeadDestination(lat, lng, null, null, headingDegrees);
    final parts = destStr.split(',');
    if (parts.length != 2) return null;
    final dlat = double.tryParse(parts[0].trim());
    final dlng = double.tryParse(parts[1].trim());
    if (dlat == null || dlng == null) return null;
    final brg = (headingDegrees != null && headingDegrees.isFinite) ? headingDegrees : 0.0;
    final distM = _snapLegDistanceM(lat, lng, dlat, dlng);
    final n = _snapCorridorPointCount(distM);
    final t0 = _snapStartInstant(locationFixTimeUtcMs);
    final totalMs = _snapTotalDurationMs(distM, speedMpsForSnapTiming);
    final pts = StringBuffer();
    final hds = StringBuffer();
    final timestamps = StringBuffer();
    for (var i = 0; i < n; i++) {
      if (i > 0) {
        pts.write(';');
        hds.write(';');
        timestamps.write(';');
      }
      final frac = n <= 1 ? 0.0 : i / (n - 1);
      final alongM = distM * frac;
      final o = Geo.offsetLatLngMeters(lat, lng, brg, alongM);
      pts.write('${o.lng.toStringAsFixed(7)},${o.lat.toStringAsFixed(7)}');
      hds.write(brg.toStringAsFixed(1));
      final offsetMs = n <= 1 ? 0 : (totalMs * i) ~/ (n - 1);
      final instant = t0.add(Duration(milliseconds: offsetMs));
      timestamps.write(instant.toIso8601String());
    }
    final uri = Uri.https('api.tomtom.com', '/snapToRoads/1', {
      'key': AppConfig.tomtomApiKey.trim(),
      'points': pts.toString(),
      'headings': hds.toString(),
      'timestamps': timestamps.toString(),
      'fields': _snapFieldsRouteGeometrySpeed,
      'vehicleType': 'PassengerCar',
      'measurementSystem': 'auto',
      'offroadMargin': '${SpeedProviderConstants.tomtomSnapOffroadMarginM}',
    });
    try {
      final res = await SpeedLimitHttpLogInterceptor.get(
        uri,
        category: 'TomTom',
        headers: _httpHeaders,
      ).timeout(_httpTimeout);
      if (res.statusCode != 200) {
        _logD(
          'TomTom route snap HTTP ${res.statusCode}: ${_httpErrorSnippet(res.body)}',
        );
        return null;
      }
      final s = res.body.trim();
      return s.isEmpty ? null : s;
    } catch (e) {
      _logD('TomTom route snap: $e');
      return null;
    }
  }

  static const String _snapFieldsRouteGeometrySpeed =
      '{projectedPoints{type,geometry{type,coordinates},properties{routeIndex,snapResult}},'
      'route{type,geometry{type,coordinates},properties{id,speedLimits{value,unit,type}}}}';
}
