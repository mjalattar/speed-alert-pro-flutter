// TomTom / Mapbox comparison consumers only (CompareRouteFetchOutcome). Never drives the debounced
// alert limit in LocationProcessor — that path is HERE-only via SpeedLimitAggregator.fetchHereForAlerts.

import 'dart:async';
import 'dart:developer' as developer;

import '../config/app_config.dart';
import '../core/android_location_compat.dart';
import '../logging/speed_limit_api_request_logger.dart';
import '../logging/speed_limit_http_log_interceptor.dart';
import '../logging/speed_limit_logging_context.dart';
import '../core/constants.dart';
import '../core/geo.dart';
import '../engine/annotation_section_speed_model.dart';
import '../engine/cross_track_geometry.dart';
import '../models/speed_limit_data.dart';
import 'preferences_manager.dart';

void _speedLimitAggregatorLogD(String message) {
  developer.log(message, name: 'SpeedLimitAggregator');
}

void _speedLimitAggregatorLogE(String message, Object e, StackTrace st) {
  developer.log(message, name: 'SpeedLimitAggregator', error: e, stackTrace: st);
}

String _httpErrorSnippet(String body, [int maxChars = 400]) {
  if (body.length <= maxChars) return body;
  return '${body.substring(0, maxChars)}…';
}

/// Outcome of a TomTom / Mapbox compare fetch — mirrors Kotlin [CompareRouteFetchOutcome].
class CompareRouteFetchOutcome {
  CompareRouteFetchOutcome(this.data, this.sectionModel);

  final SpeedLimitData data;
  final AnnotationSectionSpeedModel? sectionModel;
}

/// TomTom Snap + Mapbox Directions compare (mirrors Android [SpeedLimitAggregator] compare APIs).
///
/// HTTP behavior matches [TomTomApiService] / [MapboxApiService] (OkHttp 30s connect+read, same headers).
class CompareProvidersService {
  CompareProvidersService({
    required this.preferencesManager,
    this.onCacheChanged,
  });

  final PreferencesManager preferencesManager;
  void Function()? onCacheChanged;

  /// Kotlin [OkHttpClient] connectTimeout + readTimeout for TomTom/Mapbox clients.
  static const Duration _httpTimeout = Duration(seconds: 30);

  /// Kotlin [TomTomApiService] / [MapboxApiService] OkHttp header [Interceptor].
  static const Map<String, String> _tomTomHttpHeaders = {
    'Accept': 'application/json',
    'User-Agent': 'SpeedAlertPro/1.0',
  };

  /// Kotlin [MapboxApiService] POST: same headers as GET plus form [Content-Type].
  static const Map<String, String> _mapboxPostHeaders = {
    'Accept': 'application/json',
    'User-Agent': 'SpeedAlertPro/1.0',
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  /// Kotlin [MapboxApiService] GET fallback (no form body).
  static const Map<String, String> _mapboxGetHeaders = {
    'Accept': 'application/json',
    'User-Agent': 'SpeedAlertPro/1.0',
  };

  SpeedLimitData? _cachedTomTomCompare;
  SpeedLimitData? _cachedMapboxCompare;

  void clearCompareProviderStickyCache() {
    _cachedTomTomCompare = null;
    _cachedMapboxCompare = null;
    onCacheChanged?.call();
    _afterCompareCacheMutation('clear');
  }

  void clearTomTomCompareStickyCacheOnly() {
    _cachedTomTomCompare = null;
    onCacheChanged?.call();
    _afterCompareCacheMutation('tomtom_clear');
  }

  void clearMapboxCompareStickyCacheOnly() {
    _cachedMapboxCompare = null;
    onCacheChanged?.call();
    _afterCompareCacheMutation('mapbox_clear');
  }

  (int?, int?) peekCachedCompareTomTomMapboxMph() {
    return (_cachedTomTomCompare?.speedLimitMph, _cachedMapboxCompare?.speedLimitMph);
  }

  /// Kotlin [SpeedLimitAggregator] compare cache read (progressive UI).
  SpeedLimitData? peekCachedTomTomCompare() => _cachedTomTomCompare;

  SpeedLimitData? peekCachedMapboxCompare() => _cachedMapboxCompare;

  void publishTomTomCompareFromAlong(SpeedLimitData data) {
    _cachedTomTomCompare = data;
    onCacheChanged?.call();
    _afterCompareCacheMutation('tomtom_along');
  }

  void publishMapboxCompareFromAlong(SpeedLimitData data) {
    _cachedMapboxCompare = data;
    onCacheChanged?.call();
    _afterCompareCacheMutation('mapbox_along');
  }

  void _afterCompareCacheMutation(String trigger) {
    final ttOn = preferencesManager.isTomTomApiEnabled;
    final mbOn = preferencesManager.isMapboxApiEnabled;
    if (!ttOn && !mbOn) {
      SpeedLimitLoggingContext.setCompareProviderMphCells('clear', null, null);
      return;
    }
    final ttData = _cachedTomTomCompare;
    final mbData = _cachedMapboxCompare;
    SpeedLimitLoggingContext.setCompareProviderMphCells(
      trigger,
      ttData?.speedLimitMph,
      mbData?.speedLimitMph,
    );
    unawaited(
      SpeedLimitApiRequestLogger.appendCompareCacheUpdate(
        preferencesManager: preferencesManager,
        trigger: trigger,
        tomtomData: ttData,
        mapboxData: mbData,
      ),
    );
  }

  void _recordTomTomCompare(SpeedLimitData data) {
    _cachedTomTomCompare = data;
    onCacheChanged?.call();
    _afterCompareCacheMutation('tomtom_fetch');
  }

  void _recordMapboxCompare(SpeedLimitData data) {
    _cachedMapboxCompare = data;
    onCacheChanged?.call();
    _afterCompareCacheMutation('mapbox_fetch');
  }

  Future<CompareRouteFetchOutcome> fetchTomTomForCompare({
    required double latitude,
    required double longitude,
    double? headingDegrees,
    int? locationFixTimeUtcMs,
    double? speedMpsForSnapTiming,
  }) async {
    if (!preferencesManager.isTomTomApiEnabled) {
      return CompareRouteFetchOutcome(_disabledProviderData('TomTom'), null);
    }
    final key = AppConfig.tomtomApiKey.trim();
    if (key.isEmpty) {
      return CompareRouteFetchOutcome(
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
      final routeJson = await _fetchTomTomSnapRouteJsonForCompare(
        latitude,
        longitude,
        headingDegrees,
        locationFixTimeUtcMs,
        speedMpsForSnapTiming,
      );
      final model = routeJson != null
          ? AnnotationSectionSpeedModel.fromTomTomSnapRouteJson(routeJson)
          : null;
      if (model != null) {
        final along = CrossTrackGeometry.alongPolylineMeters(
          latitude,
          longitude,
          model.geometry,
        );
        final data = model.speedLimitDataAtAlong(along);
        _recordTomTomCompare(data);
        return CompareRouteFetchOutcome(data, model);
      }
      const data = SpeedLimitData(
        provider: 'TomTom',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source:
            'TomTom compare: no route model from snap (same single-call policy as HERE)',
      );
      _recordTomTomCompare(data);
      return CompareRouteFetchOutcome(data, null);
    } catch (e, st) {
      final errorMsg = '$e';
      _speedLimitAggregatorLogE('TomTom API error: $errorMsg', e, st);
      final data = SpeedLimitData(
        provider: 'TomTom',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'TomTom API - Error: $errorMsg',
      );
      _recordTomTomCompare(data);
      return CompareRouteFetchOutcome(data, null);
    }
  }

  Future<CompareRouteFetchOutcome> fetchMapboxForCompare({
    required double latitude,
    required double longitude,
    double? headingDegrees,
  }) async {
    if (!preferencesManager.isMapboxApiEnabled) {
      return CompareRouteFetchOutcome(_disabledProviderData('Mapbox'), null);
    }
    final token = AppConfig.mapboxAccessToken.trim();
    if (token.isEmpty) {
      return CompareRouteFetchOutcome(
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
      final routeJson = await _fetchMapboxDirectionsRouteJsonForCompare(
        latitude,
        longitude,
        headingDegrees,
        token,
      );
      final model = routeJson != null
          ? AnnotationSectionSpeedModel.fromMapboxDirectionsJson(routeJson)
          : null;
      if (model != null) {
        final along = CrossTrackGeometry.alongPolylineMeters(
          latitude,
          longitude,
          model.geometry,
        );
        final data = model.speedLimitDataAtAlong(along);
        _recordMapboxCompare(data);
        return CompareRouteFetchOutcome(data, model);
      }
      const data = SpeedLimitData(
        provider: 'Mapbox',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source:
            'Mapbox compare: no route model from directions (same single-call policy as HERE)',
      );
      _recordMapboxCompare(data);
      return CompareRouteFetchOutcome(data, null);
    } catch (e, st) {
      final errorMsg = '$e';
      _speedLimitAggregatorLogE('Mapbox API error: $errorMsg', e, st);
      final data = SpeedLimitData(
        provider: 'Mapbox',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Mapbox API - Error: $errorMsg',
      );
      _recordMapboxCompare(data);
      return CompareRouteFetchOutcome(data, null);
    }
  }

  /// Kotlin [SpeedLimitAggregator.disabledProviderData] — [source] is exactly `"Disabled in settings"`.
  static SpeedLimitData _disabledProviderData(String name) {
    return SpeedLimitData(
      provider: name,
      speedLimitMph: null,
      confidence: ConfidenceLevel.low,
      source: 'Disabled in settings',
    );
  }

  /// Same as Kotlin [SpeedLimitAggregator.hereAlertDestination].
  static String _hereAlertDestination(
    double lat,
    double lng,
    double? destLat,
    double? destLng,
    double? headingDegrees,
  ) {
    if (destLat != null && destLng != null) return '$destLat,$destLng';
    if (headingDegrees != null && headingDegrees.isFinite) {
      final o = Geo.offsetLatLngMeters(lat, lng, headingDegrees, kAlertRouteLeadMeters);
      return '${o.lat},${o.lng}';
    }
    return '${lat + 0.00001},${lng + 0.00001}';
  }

  static double _tomTomSnapLegDistanceM(
    double lat,
    double lng,
    double destLat,
    double destLng,
  ) {
    final d = AndroidLocationCompat.distanceBetweenMeters(lat, lng, destLat, destLng);
    return d < 5.0 ? 5.0 : d;
  }

  static int _tomTomSnapCorridorPointCount(double distanceM) {
    const spacing = 120.0;
    const maxPoints = 12;
    final segments = (distanceM / spacing).ceil().clamp(1, 999999);
    return (segments + 1).clamp(2, maxPoints);
  }

  static DateTime _tomTomSnapStartInstant(int? locationFixTimeUtcMs) {
    if (locationFixTimeUtcMs != null && locationFixTimeUtcMs > 0) {
      return DateTime.fromMillisecondsSinceEpoch(locationFixTimeUtcMs, isUtc: true);
    }
    return DateTime.now().toUtc();
  }

  static int _tomTomSnapTotalDurationMs(double distM, double? speedMpsHint) {
    var speedMps = (speedMpsHint != null && speedMpsHint >= 1.0)
        ? speedMpsHint.toDouble()
        : 28.0;
    speedMps = speedMps.clamp(6.0, 55.0);
    final dtSec = (distM / speedMps).round().clamp(3, 600);
    return dtSec * 1000;
  }

  Future<String?> _fetchTomTomSnapRouteJsonForCompare(
    double lat,
    double lng,
    double? headingDegrees,
    int? locationFixTimeUtcMs,
    double? speedMpsForSnapTiming,
  ) async {
    final destStr = _hereAlertDestination(lat, lng, null, null, headingDegrees);
    final parts = destStr.split(',');
    if (parts.length != 2) return null;
    final dlat = double.tryParse(parts[0].trim());
    final dlng = double.tryParse(parts[1].trim());
    if (dlat == null || dlng == null) return null;
    final brg = (headingDegrees != null && headingDegrees.isFinite) ? headingDegrees : 0.0;
    final distM = _tomTomSnapLegDistanceM(lat, lng, dlat, dlng);
    final n = _tomTomSnapCorridorPointCount(distM);
    final t0 = _tomTomSnapStartInstant(locationFixTimeUtcMs);
    final totalMs = _tomTomSnapTotalDurationMs(distM, speedMpsForSnapTiming);
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
      // Kotlin: `val offsetMs = (totalMs * i / (n - 1))` — Long integer division, not float round-trip.
      final offsetMs = n <= 1 ? 0 : (totalMs * i) ~/ (n - 1);
      final instant = t0.add(Duration(milliseconds: offsetMs));
      timestamps.write(instant.toIso8601String());
    }
    // Retrofit [TomTomApiService.snapToRoadsGet]: all @Query params including defaults.
    final uri = Uri.https('api.tomtom.com', '/snapToRoads/1', {
      'key': AppConfig.tomtomApiKey.trim(),
      'points': pts.toString(),
      'headings': hds.toString(),
      'timestamps': timestamps.toString(),
      'fields': _snapFieldsRouteGeometrySpeed,
      'vehicleType': 'PassengerCar',
      'measurementSystem': 'auto',
    });
    try {
      final res = await SpeedLimitHttpLogInterceptor.get(
        uri,
        category: 'TomTom',
        headers: _tomTomHttpHeaders,
      ).timeout(_httpTimeout);
      if (res.statusCode != 200) {
        // Kotlin [SpeedLimitAggregator]: Log.d on HttpException + body for debugging.
        _speedLimitAggregatorLogD(
          'TomTom route snap HTTP ${res.statusCode}: ${_httpErrorSnippet(res.body)}',
        );
        return null;
      }
      final s = res.body.trim();
      return s.isEmpty ? null : s;
    } catch (e) {
      _speedLimitAggregatorLogD('TomTom route snap: $e');
      return null;
    }
  }

  Future<String?> _fetchMapboxDirectionsRouteJsonForCompare(
    double lat,
    double lng,
    double? headingDegrees,
    String token,
  ) async {
    final destStr = _hereAlertDestination(lat, lng, null, null, headingDegrees);
    final parts = destStr.split(',');
    if (parts.length != 2) return null;
    final dlat = double.tryParse(parts[0].trim());
    final dlng = double.tryParse(parts[1].trim());
    if (dlat == null || dlng == null) return null;
    final coordStr =
        '${_formatMapboxCoord(lng, lat)};${_formatMapboxCoord(dlng, dlat)}';
    final br = _mapboxBearingsAndRadiuses(headingDegrees);
    final q = <String, String>{
      'access_token': token,
      'radiuses': br.$2,
    };
    if (br.$1 != null) q['bearings'] = br.$1!;
    // Retrofit [MapboxApiService]: @Query on URL; @Field defaults on body (encoded=true for coordinates).
    final uri = Uri.parse('https://api.mapbox.com/directions/v5/mapbox/driving')
        .replace(queryParameters: q);
    // Do not Uri.encodeComponent(coordStr): Kotlin @Field(encoded = true) — semicolons stay literal (Mapbox doc).
    final body =
        'coordinates=$coordStr&annotations=maxspeed&geometries=geojson&overview=full';
    try {
      final res = await SpeedLimitHttpLogInterceptor.post(
        uri,
        headers: _mapboxPostHeaders,
        body: body,
        category: 'Mapbox',
      ).timeout(_httpTimeout);
      if (res.statusCode == 200 && res.body.isNotEmpty) return res.body;
      _speedLimitAggregatorLogD(
        'Mapbox route POST HTTP ${res.statusCode}: ${_httpErrorSnippet(res.body)}',
      );
    } catch (e) {
      _speedLimitAggregatorLogD('Mapbox route POST: $e');
    }
    try {
      // [MapboxApiService.getDirectionsJson] @Path(coordinates, encoded = true): raw lon,lat;lon,lat path.
      final getUri = Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/driving/$coordStr',
      ).replace(queryParameters: q);
      final res = await SpeedLimitHttpLogInterceptor.get(
        getUri,
        category: 'Mapbox',
        headers: _mapboxGetHeaders,
      ).timeout(_httpTimeout);
      if (res.statusCode == 200 && res.body.isNotEmpty) return res.body;
      _speedLimitAggregatorLogD(
        'Mapbox route GET HTTP ${res.statusCode}: ${_httpErrorSnippet(res.body)}',
      );
    } catch (e) {
      _speedLimitAggregatorLogD('Mapbox route GET: $e');
    }
    return null;
  }

  static String _formatMapboxCoord(double lon, double la) =>
      '${lon.toStringAsFixed(6)},${la.toStringAsFixed(6)}';

  static const int _mapboxWaypointRadiusM = 50;
  static const int _mapboxBearingToleranceDeg = 45;

  static (String?, String) _mapboxBearingsAndRadiuses(double? headingDegrees) {
    const radiuses = '$_mapboxWaypointRadiusM;$_mapboxWaypointRadiusM';
    if (headingDegrees == null || !headingDegrees.isFinite) {
      return (null, radiuses);
    }
    final norm = ((headingDegrees.round() % 360) + 360) % 360;
    final b =
        '$norm,$_mapboxBearingToleranceDeg;$norm,$_mapboxBearingToleranceDeg';
    return (b, radiuses);
  }

  /// TomTom [TomTomApiService.SNAP_FIELDS_ROUTE_GEOMETRY_SPEED].
  static const String _snapFieldsRouteGeometrySpeed =
      '{projectedPoints{type,geometry{type,coordinates},properties{routeIndex,snapResult}},'
      'route{type,geometry{type,coordinates},properties{id,speedLimits{value,unit,type}}}}';
}
