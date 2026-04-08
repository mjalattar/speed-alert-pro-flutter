// Mapbox Directions — speed limit provider (primary or secondary).

import 'dart:async';
import 'dart:developer' as developer;

import '../../config/app_config.dart';
import '../../core/speed_provider_constants.dart';
import '../../engine/compare/compare_section_speed_model.dart';
import '../../engine/mapbox/cross_track_geometry.dart';
import '../../logging/speed_limit_api_request_logger.dart';
import '../../logging/speed_limit_logging_context.dart';
import '../../logging/speed_limit_http_log_interceptor.dart';
import '../../models/speed_limit_data.dart';
import '../preferences_manager.dart';
import '../speed_providers/route_fetch_models.dart';
import '../speed_providers/route_lead_geometry.dart';

void _logD(String message) {
  developer.log(message, name: 'MapboxSpeed');
}

String _httpErrorSnippet(String body, [int maxChars = 400]) {
  if (body.length <= maxChars) return body;
  return '${body.substring(0, maxChars)}…';
}

/// Mapbox Directions API (`annotations=maxspeed`, `overview=full`).
class MapboxSpeedProvider {
  MapboxSpeedProvider({
    required this.preferencesManager,
    this.onSliceChanged,
  });

  final PreferencesManager preferencesManager;

  /// Called after cache mutation (`mapbox_fetch`, `mapbox_along`, `mapbox_clear`).
  void Function(String trigger)? onSliceChanged;

  static const Duration _httpTimeout = Duration(seconds: 30);

  static const Map<String, String> _postHeaders = {
    'Accept': 'application/json',
    'User-Agent': 'SpeedAlertPro/1.0',
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  static const Map<String, String> _getHeaders = {
    'Accept': 'application/json',
    'User-Agent': 'SpeedAlertPro/1.0',
  };

  SpeedLimitData? _cachedLimit;

  void clearStickyCacheOnly() {
    _cachedLimit = null;
    _emitMapboxCacheLogging('mapbox_clear');
    onSliceChanged?.call('mapbox_clear');
  }

  SpeedLimitData? peekCached() => _cachedLimit;

  void publishFromAlong(SpeedLimitData data) {
    _cachedLimit = data;
    _emitMapboxCacheLogging('mapbox_along');
    onSliceChanged?.call('mapbox_along');
  }

  void _emitMapboxCacheLogging(String trigger) {
    final mph = _cachedLimit?.speedLimitMph;
    SpeedLimitLoggingContext.setMapboxMphCell(trigger, mph);
    unawaited(
      SpeedLimitApiRequestLogger.appendMapboxStickyCacheLog(
        preferencesManager: preferencesManager,
        trigger: trigger,
        mapboxData: _cachedLimit,
      ),
    );
  }

  Future<RouteFetchOutcome> fetchSpeedLimit({
    required double latitude,
    required double longitude,
    double? headingDegrees,
    MapboxPolylineMatchingOptions? polylineMatchingOptions,
  }) async {
    if (!preferencesManager.isMapboxApiEnabled) {
      return RouteFetchOutcome(_disabledProviderData(), null);
    }
    final token = AppConfig.mapboxAccessToken.trim();
    if (token.isEmpty) {
      return RouteFetchOutcome(
        const SpeedLimitData(
          provider: 'Mapbox',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'API key not configured',
        ),
        null,
      );
    }
    try {
      final routeJson = await _fetchDirectionsRouteJson(
        latitude,
        longitude,
        headingDegrees,
        token,
      );
      final model = routeJson != null
          ? AnnotationSectionSpeedModel.fromMapboxDirectionsJson(
              routeJson,
              vehicleLat: latitude,
              vehicleLng: longitude,
              headingDegrees: headingDegrees,
            )
          : null;
      if (model != null) {
        final matchOpts =
            polylineMatchingOptions?.withEdgeMph(model.mphHintsPerEdge());
        final along = MapboxCrossTrackGeometry.alongPolylineMetersForMatching(
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
        provider: 'Mapbox',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source:
            'Mapbox: no route model from directions',
      );
      _recordLimit(data);
      return RouteFetchOutcome(data, null);
    } catch (e, st) {
      final errorMsg = '$e';
      developer.log(
        'Mapbox API error: $errorMsg',
        name: 'MapboxSpeed',
        error: e,
        stackTrace: st,
      );
      final data = SpeedLimitData(
        provider: 'Mapbox',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Mapbox API - Error: $errorMsg',
      );
      _recordLimit(data);
      return RouteFetchOutcome(data, null);
    }
  }

  SpeedLimitData _disabledProviderData() => const SpeedLimitData(
        provider: 'Mapbox',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Disabled in settings',
      );

  void _recordLimit(SpeedLimitData data) {
    _cachedLimit = data;
    _emitMapboxCacheLogging('mapbox_fetch');
    onSliceChanged?.call('mapbox_fetch');
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
    final edge = AnnotationSectionSpeedModel.mapboxVehicleEdgeProjectionFromDirectionsJson(
      routeJson,
      latitude,
      longitude,
      headingDegrees,
    );
    unawaited(
      SpeedLimitApiRequestLogger.appendMapboxFetchDiagnostics(
        preferencesManager: preferencesManager,
        vehicleLat: latitude,
        vehicleLng: longitude,
        bearingDeg: headingDegrees,
        alongMeters: along,
        leadDestLatLng: lead,
        reportedMph: data.speedLimitMph,
        sliceMph: slice,
        mapboxEdge: edge,
      ),
    );
  }

  Future<String?> _fetchDirectionsRouteJson(
    double lat,
    double lng,
    double? headingDegrees,
    String token,
  ) async {
    final destStr = routeLeadDestination(lat, lng, null, null, headingDegrees);
    final parts = destStr.split(',');
    if (parts.length != 2) return null;
    final dlat = double.tryParse(parts[0].trim());
    final dlng = double.tryParse(parts[1].trim());
    if (dlat == null || dlng == null) return null;
    final coordStr =
        '${_formatCoord(lng, lat)};${_formatCoord(dlng, dlat)}';
    final br = _bearingsAndRadiuses(headingDegrees);
    final q = <String, String>{
      'access_token': token,
      'radiuses': br.$2,
      'alternatives': 'false',
      'steps': 'false',
    };
    if (br.$1 != null) q['bearings'] = br.$1!;
    final uri = Uri.parse('https://api.mapbox.com/directions/v5/mapbox/driving')
        .replace(queryParameters: q);
    final body =
        'coordinates=$coordStr&annotations=maxspeed&geometries=geojson&overview=full';
    try {
      final res = await SpeedLimitHttpLogInterceptor.post(
        uri,
        headers: _postHeaders,
        body: body,
        category: 'Mapbox',
      ).timeout(_httpTimeout);
      if (res.statusCode == 200 && res.body.isNotEmpty) return res.body;
      _logD(
        'Mapbox route POST HTTP ${res.statusCode}: ${_httpErrorSnippet(res.body)}',
      );
    } catch (e) {
      _logD('Mapbox route POST: $e');
    }
    try {
      final getUri = Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/driving/$coordStr',
      ).replace(queryParameters: q);
      final res = await SpeedLimitHttpLogInterceptor.get(
        getUri,
        category: 'Mapbox',
        headers: _getHeaders,
      ).timeout(_httpTimeout);
      if (res.statusCode == 200 && res.body.isNotEmpty) return res.body;
      _logD(
        'Mapbox route GET HTTP ${res.statusCode}: ${_httpErrorSnippet(res.body)}',
      );
    } catch (e) {
      _logD('Mapbox route GET: $e');
    }
    return null;
  }

  static String _formatCoord(double lon, double la) =>
      '${lon.toStringAsFixed(6)},${la.toStringAsFixed(6)}';

  static (String?, String) _bearingsAndRadiuses(double? headingDegrees) {
    final r = SpeedProviderConstants.mapboxSecondaryWaypointRadiusM;
    final radiuses = '$r;$r';
    if (headingDegrees == null || !headingDegrees.isFinite) {
      return (null, radiuses);
    }
    final norm = ((headingDegrees.round() % 360) + 360) % 360;
    final tol = SpeedProviderConstants.mapboxBearingToleranceDeg;
    final b = '$norm,$tol;$norm,$tol';
    return (b, radiuses);
  }
}
