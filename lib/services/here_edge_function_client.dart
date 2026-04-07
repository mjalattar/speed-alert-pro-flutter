import 'dart:convert';

import '../config/app_config.dart';
import '../logging/speed_limit_api_session_counter.dart';
import '../logging/speed_limit_http_log_interceptor.dart';
import '../engine/geo_coordinate.dart';
import '../core/polyline_decoder.dart';
import '../models/speed_limit_data.dart';

/// Flutter port of Kotlin [HereEdgeFunctionClient] — Supabase Edge `here-speed`.
class HereEdgeFunctionClient {
  HereEdgeFunctionClient({required this.accessTokenProvider});

  /// Kotlin constructor [accessTokenProvider]: suspend () -> String
  final Future<String> Function() accessTokenProvider;

  Uri get _url =>
      Uri.parse('${AppConfig.supabaseUrl.trim().replaceAll(RegExp(r'/$'), '')}'
          '/functions/v1/here-speed');

  Future<SpeedLimitData> fetchAlertSpeedMph({
    required double lat,
    required double lng,
    double? destLat,
    double? destLng,
    double? headingDegrees,
  }) async {
    final token = await accessTokenProvider();
    // Gson default: null fields omitted — matches Kotlin [HereEdgeAlertBody] serialization.
    final bodyMap = <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'kind': 'alert',
    };
    if (destLat != null) bodyMap['dest_lat'] = destLat;
    if (destLng != null) bodyMap['dest_lng'] = destLng;
    if (headingDegrees != null && headingDegrees.isFinite) {
      bodyMap['heading_degrees'] = headingDegrees;
    }
    final body = jsonEncode(bodyMap);

    final res = await SpeedLimitHttpLogInterceptor.post(
      _url,
      headers: {
        'Authorization': 'Bearer $token',
        'apikey': AppConfig.supabaseAnonKey,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: body,
      category: 'Supabase_here-speed',
      countTowardSession: false,
    );
    // Kotlin [HereEdgeFunctionClient]: count after successful OkHttp execute(), not on IOException.
    SpeedLimitApiSessionCounter.recordIfSessionActive();

    if (res.statusCode == 402) {
      return const SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Subscription or trial required',
      );
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final msg = _edgeHttpErrorMessage(res.body);
      return SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Edge: HTTP ${res.statusCode} — $msg',
      );
    }

    final map = jsonDecode(res.body) as Map<String, dynamic>;
    final err = map['error'] as String?;
    if (err != null && err.isNotEmpty) {
      return SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: err,
      );
    }

    final mph = map['speed_limit_mph'];
    final cached = map['cached'] as bool?;
    final src = cached == true
        ? 'HERE (cached)'
        : (map['source'] as String? ?? 'HERE (edge)');
    if (mph is int) {
      return SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: mph,
        confidence: ConfidenceLevel.high,
        source: src,
      );
    }
    if (mph is num) {
      return SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: mph.round(),
        confidence: ConfidenceLevel.high,
        source: src,
      );
    }

    return SpeedLimitData(
      provider: 'HERE Maps',
      speedLimitMph: null,
      confidence: ConfidenceLevel.low,
      source: src,
    );
  }

  /// Kotlin [HereEdgeFunctionClient] `kind: "route"` — full HERE-shaped body + decoded polyline
  /// (same JSON [HereApiService.parseAlertFetchFromDecodedRoute] expects for span / section model).
  Future<({List<GeoCoordinate> geometry, Map<String, dynamic> root})?> fetchRoutePolylineForSimulation({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
  }) async {
    final token = await accessTokenProvider();
    final body = jsonEncode({
      'lat': originLat,
      'lng': originLng,
      'dest_lat': destLat,
      'dest_lng': destLng,
      'kind': 'route',
    });

    final res = await SpeedLimitHttpLogInterceptor.post(
      _url,
      headers: {
        'Authorization': 'Bearer $token',
        'apikey': AppConfig.supabaseAnonKey,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: body,
      category: 'Supabase_here-speed',
      countTowardSession: false,
    );
    SpeedLimitApiSessionCounter.recordIfSessionActive();

    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final root = jsonDecode(res.body) as Map<String, dynamic>;
    final err = root['error'] as String?;
    if (err != null && err.isNotEmpty) return null;

    final routes = root['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) return null;
    final route = routes.first as Map<String, dynamic>?;
    final sections = route?['sections'] as List<dynamic>?;
    if (sections == null || sections.isEmpty) return null;
    final section = sections.first as Map<String, dynamic>?;
    final poly = section?['polyline'] as String?;
    if (poly == null || poly.isEmpty) return null;
    final decoded = PolylineDecoder.decode(poly);
    if (decoded.length < 2) return null;
    return (geometry: decoded, root: root);
  }
}

String _edgeHttpErrorMessage(String body) {
  try {
    final map = jsonDecode(body) as Map<String, dynamic>?;
    final err = map?['error'] as String?;
    final message = map?['message'] as String?;
    final s = err ?? message ?? body;
    return s.length > 200 ? s.substring(0, 200) : s;
  } catch (_) {
    return body.length > 200 ? body.substring(0, 200) : body;
  }
}
