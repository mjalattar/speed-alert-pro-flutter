import 'dart:convert';

import '../core/android_location_compat.dart';
import '../core/constants.dart';
import '../logging/here_span_fetch_session_logger.dart';
import '../logging/logging_globals.dart';
import '../logging/speed_limit_http_log_interceptor.dart';
import '../core/geo.dart';
import '../engine/cross_track_geometry.dart';
import '../engine/geo_bearing.dart' as gb;
import '../engine/geo_coordinate.dart';
import '../engine/here_route_speed_limits.dart';
import '../engine/here_section_speed_model.dart';
import '../core/polyline_decoder.dart';
import '../models/here_alert_fetch_result.dart';
import '../models/road_segment.dart';
import '../models/speed_limit_data.dart';

/// Local HERE Routing API client ([router.hereapi.com](https://router.hereapi.com) v8).
class HereApiService {
  HereApiService({required this.apiKey});

  /// HERE router base URL.
  static const String baseUrl = 'https://router.hereapi.com/';

  /// Factory with explicit API key.
  static HereApiService create({required String apiKey}) =>
      HereApiService(apiKey: apiKey);

  final String apiKey;

  static final Uri _routesUri = Uri.parse('${baseUrl}v8/routes');

  /// Road-test simulation: one O–D `v8/routes` call whose JSON drives the map polyline **and**
  /// [HereSectionSpeedModel] priming so [LocationProcessor] walks spans on the **same** geometry as the
  /// mock vehicle (avoids a divergent second alert-leg route and refetch storms).
  Future<({List<GeoCoordinate> geometry, HereSectionSpeedModel? sectionSpeedModel})?>
      fetchSimulationOdRouteWithSection({
    required String origin,
    required String destination,
  }) async {
    final uri = _routesUri.replace(queryParameters: {
      'transportMode': 'car',
      'origin': origin,
      'destination': destination,
      'routingMode': 'short',
      'return': 'polyline',
      'spans': 'speedLimit,segmentRef,functionalClass',
      'apiKey': apiKey,
    });
    final res = await SpeedLimitHttpLogInterceptor.get(
      uri,
      category: 'HERE_Routing',
    );
    if (res.statusCode != 200) return null;
    final root = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = root['routes'] as List<dynamic>?;
    final route = routes?.isNotEmpty == true ? routes!.first as Map<String, dynamic> : null;
    final sections = route?['sections'] as List<dynamic>?;
    final section = sections?.isNotEmpty == true ? sections!.first as Map<String, dynamic> : null;
    final poly = section?['polyline'] as String?;
    if (poly == null || poly.isEmpty) return null;
    final geometry = PolylineDecoder.decode(poly);
    if (geometry.length < 2) return null;

    double? oLat;
    double? oLng;
    final parts = origin.split(',');
    if (parts.length == 2) {
      oLat = double.tryParse(parts[0].trim());
      oLng = double.tryParse(parts[1].trim());
    }
    final atLat = oLat ?? geometry.first.lat;
    final atLng = oLng ?? geometry.first.lng;

    final prefs = speedAlertLoggingPreferences;
    if (prefs != null) {
      HereSpanFetchSessionLogger.recordLocalRouteIfApplicable(prefs, atLat, atLng, root);
    }

    final parsed = parseAlertFetchFromDecodedRoute(
      root,
      lat: atLat,
      lng: atLng,
      headingDegrees: null,
    );
    return (geometry: geometry, sectionSpeedModel: parsed.sectionSpeedModel);
  }

  /// Parses alert limit, optional sticky segment, and section model from a decoded `v8/routes` body.
  ///
  /// [headingDegrees]: motion heading for polyline matching (weighted segment choice). When null,
  /// a **start-of-route** tangent is used only if [(lat,lng)] is within ~40 m of the first vertex.
  HereAlertFetchResult parseAlertFetchFromDecodedRoute(
    Map<String, dynamic> root, {
    required double lat,
    required double lng,
    double? headingDegrees,
  }) {
    final routes = root['routes'] as List<dynamic>?;
    final route = routes?.isNotEmpty == true ? routes!.first as Map<String, dynamic> : null;
    if (route == null) {
      return HereAlertFetchResult(
        data: const SpeedLimitData(
          provider: 'HERE Maps',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'No route',
        ),
      );
    }
    final sections = route['sections'] as List<dynamic>?;
    final section = sections?.isNotEmpty == true ? sections!.first as Map<String, dynamic> : null;
    final poly = section?['polyline'] as String? ?? '';
    final geometry = PolylineDecoder.decode(poly);
    final spanList = section?['spans'] as List<dynamic>? ?? [];
    final spans = spanList
        .map((e) => HereSpan.fromHereRoutingApiJson(e as Map<String, dynamic>))
        .toList();

    HereSectionSpeedModel? sectionModel;
    if (section != null && geometry.length >= 2 && spans.isNotEmpty) {
      sectionModel = HereSectionSpeedModel.build(spans, geometry);
    }

    double? effectiveHeading = headingDegrees;
    if ((effectiveHeading == null || !effectiveHeading.isFinite) &&
        geometry.length >= 2) {
      final d0 = AndroidLocationCompat.distanceBetweenMeters(
        lat,
        lng,
        geometry.first.lat,
        geometry.first.lng,
      );
      if (d0 < 40.0) {
        effectiveHeading = gb.bearingDeg(
          geometry[0].lat,
          geometry[0].lng,
          geometry[1].lat,
          geometry[1].lng,
        );
      }
    }

    final alongVehicle = geometry.length >= 2
        ? CrossTrackGeometry.alongPolylineMetersForMatching(
            lat,
            lng,
            geometry,
            effectiveHeading,
          )
        : 0.0;

    SpeedLimitData data;
    if (sectionModel != null) {
      final atAlong = sectionModel.speedLimitDataAtAlong(alongVehicle);
      data = atAlong.speedLimitMph != null
          ? atAlong
          : _fromFirstSpan(spans);
    } else {
      data = _fromFirstSpan(spans);
    }

    RoadSegment? sticky;
    if (sectionModel == null && data.speedLimitMph != null && geometry.length >= 2) {
      sticky = RoadSegment(
        linkId: data.segmentKey ?? 'geo:${geometry.first.lat},${geometry.first.lng}',
        speedLimitMph: data.speedLimitMph!.toDouble(),
        geometry: geometry,
        bearingDeg: _avgBearing(geometry),
        expiresAtMillis: DateTime.now().millisecondsSinceEpoch + 30 * 60 * 1000,
        functionalClass: data.functionalClass,
      );
    }

    return HereAlertFetchResult(
      data: data,
      stickySegment: sticky,
      sectionSpeedModel: sectionModel,
    );
  }

  /// HERE Discover geocode (e.g. simulation preset when custom lat/lng is blank).
  Future<({double lat, double lng})?> discoverFirstPosition({
    required String query,
    String at = '29.5445,-95.0205',
  }) async {
    final uri = Uri.https('discover.search.hereapi.com', '/v1/discover', {
      'q': query,
      'at': at,
      'apiKey': apiKey,
      'limit': '5',
    });
    final res = await SpeedLimitHttpLogInterceptor.get(
      uri,
      category: 'HERE_Discover',
    );
    if (res.statusCode != 200) return null;
    final root = jsonDecode(res.body) as Map<String, dynamic>;
    final items = root['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) return null;
    for (final raw in items) {
      final m = raw as Map<String, dynamic>;
      final pos = m['position'] as Map<String, dynamic>?;
      final fromMap = _latLngFromDiscoverMap(pos);
      if (fromMap != null) return fromMap;
      final access = m['access'] as List<dynamic>?;
      if (access != null) {
        for (final a in access) {
          final am = a as Map<String, dynamic>?;
          if (am == null) continue;
          final acc = _latLngFromDiscoverMap(am);
          if (acc != null) return acc;
        }
      }
    }
    return null;
  }

  ({double lat, double lng})? _latLngFromDiscoverMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final lat = (m['lat'] as num?)?.toDouble();
    final lng = (m['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return (lat: lat, lng: lng);
  }

  /// Virtual destination ~[kAlertRouteLeadMeters] ahead along [headingDegrees], when set.
  /// Used as the routing leg destination for local HERE speed-limit requests.
  String hereAlertDestination(
    double lat,
    double lng, {
    double? destLat,
    double? destLng,
    double? headingDegrees,
  }) {
    if (destLat != null && destLng != null) {
      return '$destLat,$destLng';
    }
    if (headingDegrees != null && headingDegrees.isFinite) {
      final o = Geo.offsetLatLngMeters(lat, lng, headingDegrees, kAlertRouteLeadMeters);
      return '${o.lat},${o.lng}';
    }
    return '${lat + 0.00001},${lng + 0.00001}';
  }

  /// Local HERE speed limit via routing v8 (spans + polyline return).
  Future<SpeedLimitData> getSpeedLimit({
    required double lat,
    required double lng,
    double? destLat,
    double? destLng,
    double? headingDegrees,
  }) async {
    final origin = '$lat,$lng';
    final destination = hereAlertDestination(
      lat,
      lng,
      destLat: destLat,
      destLng: destLng,
      headingDegrees: headingDegrees,
    );
    final uri = _routesUri.replace(queryParameters: {
      'transportMode': 'car',
      'origin': origin,
      'destination': destination,
      'routingMode': 'short',
      'return': 'polyline',
      'spans': 'speedLimit,segmentRef,functionalClass',
      'apiKey': apiKey,
    });

    final res = await SpeedLimitHttpLogInterceptor.get(
      uri,
      category: 'HERE_Routing',
    );
    if (res.statusCode != 200) {
      return SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'HTTP ${res.statusCode}',
      );
    }

    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final p = speedAlertLoggingPreferences;
    if (p != null) {
      HereSpanFetchSessionLogger.recordLocalRouteIfApplicable(p, lat, lng, decoded);
    }
    final routes = decoded['routes'] as List<dynamic>?;
    if (routes == null) {
      return const SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'HERE Routing API',
      );
    }
    for (final rawRoute in routes) {
      final route = rawRoute as Map<String, dynamic>;
      final sections = route['sections'] as List<dynamic>?;
      if (sections == null) continue;
      for (final rawSection in sections) {
        final section = rawSection as Map<String, dynamic>;
        final spanList = section['spans'] as List<dynamic>? ?? [];
        final spans = spanList
            .map((e) => HereSpan.fromHereRoutingApiJson(e as Map<String, dynamic>))
            .toList();
        final span = HereRouteSpeedLimits.pickSpeedSpan(spans);
        if (span != null) return speedLimitDataFromSpan(span);
      }
    }

    return const SpeedLimitData(
      provider: 'HERE Maps',
      speedLimitMph: null,
      confidence: ConfidenceLevel.low,
      source: 'HERE Routing API',
    );
  }

  /// Full HERE alert fetch: `v8/routes` request then [parseAlertFetchFromDecodedRoute].
  Future<HereAlertFetchResult> fetchHereAlertWithStickySegment({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) async {
    final uri = _routesUri.replace(queryParameters: {
      'transportMode': 'car',
      'origin': '$lat,$lng',
      'destination': hereAlertDestination(
        lat,
        lng,
        destLat: destLat,
        destLng: destLng,
        headingDegrees: headingDegrees,
      ),
      'routingMode': 'short',
      'return': 'polyline',
      'spans': 'speedLimit,segmentRef,functionalClass',
      'apiKey': apiKey,
    });
    final res = await SpeedLimitHttpLogInterceptor.get(
      uri,
      category: 'HERE_Routing',
    );
    if (res.statusCode != 200) {
      return HereAlertFetchResult(
        data: SpeedLimitData(
          provider: 'HERE Maps',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'HTTP ${res.statusCode}',
        ),
      );
    }
    final root = jsonDecode(res.body) as Map<String, dynamic>;
    final prefs = speedAlertLoggingPreferences;
    if (prefs != null) {
      HereSpanFetchSessionLogger.recordLocalRouteIfApplicable(prefs, lat, lng, root);
    }
    return parseAlertFetchFromDecodedRoute(
      root,
      lat: lat,
      lng: lng,
      headingDegrees: headingDegrees,
    );
  }

  SpeedLimitData _fromFirstSpan(List<HereSpan> spans) {
    final span = HereRouteSpeedLimits.pickSpeedSpan(spans);
    if (span != null) return speedLimitDataFromSpan(span);
    return const SpeedLimitData(
      provider: 'HERE Maps',
      speedLimitMph: null,
      confidence: ConfidenceLevel.low,
      source: 'HERE Routing API',
    );
  }

  double _avgBearing(List<GeoCoordinate> geometry) {
    if (geometry.length < 2) return 0;
    return gb.bearingDeg(
      geometry.first.lat, geometry.first.lng,
      geometry.last.lat, geometry.last.lng,
    );
  }
}
