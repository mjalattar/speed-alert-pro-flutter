// HERE Routing / Edge — map + HERE primary alerts. TomTom/Mapbox are separate services.

import '../../config/app_config.dart';
import '../../core/geo.dart';
import '../../engine/geo_coordinate.dart';
import '../../models/here_alert_fetch_result.dart';
import '../../models/road_segment.dart';
import '../../models/speed_limit_data.dart';
import '../here_api_service.dart';
import '../here_edge_function_client.dart';
import '../preferences_manager.dart';

/// Returns [Exception.message] when present, otherwise [Object.toString].
String throwableMessageOrToString(Object e) {
  try {
    final m = (e as dynamic).message;
    if (m != null) return m.toString();
  } catch (_) {}
  return e.toString();
}

/// HERE-only network: local REST [HereApiService] or Supabase Edge [HereEdgeFunctionClient].
///
/// Used for [fetchHereForAlerts] (driving pipeline) and [fetchHereMapsOnly] (map UI).
/// TomTom/Mapbox are not involved.
class HereAlertRouteProvider {
  HereAlertRouteProvider({
    required this.preferencesManager,
    required this.hereApi,
    this.hereEdgeFunctionClient,
  });

  final PreferencesManager preferencesManager;
  final HereApiService hereApi;
  final HereEdgeFunctionClient? hereEdgeFunctionClient;

  HereEdgeFunctionClient? _edgeOrNull() {
    if (!preferencesManager.useRemoteSpeedApi) return null;
    return hereEdgeFunctionClient;
  }

  /// HERE-only fetch for map / non-alert surfaces (Edge or local REST).
  Future<SpeedLimitData> fetchHereMapsOnly({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) async {
    if (!preferencesManager.isHereApiEnabled) {
      return const SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Disabled in settings',
      );
    }

    final edge = _edgeOrNull();
    if (edge != null) {
      try {
        return await edge.fetchAlertSpeedMph(
          lat: lat,
          lng: lng,
          destLat: destLat,
          destLng: destLng,
          headingDegrees: headingDegrees,
        );
      } catch (e) {
        return SpeedLimitData(
          provider: 'HERE Maps',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'HERE API - Error: ${throwableMessageOrToString(e)}',
        );
      }
    }

    if (AppConfig.hereApiKey.isEmpty) {
      return const SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Set HERE_API_KEY via --dart-define',
      );
    }

    try {
      return await hereApi.getSpeedLimit(
        lat: lat,
        lng: lng,
        headingDegrees: headingDegrees,
        destLat: destLat,
        destLng: destLng,
      );
    } catch (e) {
      return SpeedLimitData(
        provider: 'HERE Maps',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'HERE API - Error: ${throwableMessageOrToString(e)}',
      );
    }
  }

  /// Sole HERE network entry for [LocationProcessor] alert / sticky / section-walk.
  Future<HereAlertFetchResult> fetchHereForAlerts({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) async {
    if (!preferencesManager.isHereApiEnabled) {
      return HereAlertFetchResult(
        data: const SpeedLimitData(
          provider: 'HERE Maps',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'Disabled in settings',
        ),
      );
    }

    final edge = _edgeOrNull();
    if (edge != null) {
      try {
        final data = await edge.fetchAlertSpeedMph(
          lat: lat,
          lng: lng,
          destLat: destLat,
          destLng: destLng,
          headingDegrees: headingDegrees,
        );
        final sticky = buildEdgeFallbackStickySegment(
          lat,
          lng,
          headingDegrees,
          data,
        );
        return HereAlertFetchResult(data: data, stickySegment: sticky);
      } catch (e) {
        return HereAlertFetchResult(
          data: SpeedLimitData(
            provider: 'HERE Maps',
            speedLimitMph: null,
            confidence: ConfidenceLevel.low,
            source: 'HERE API - Error: ${throwableMessageOrToString(e)}',
          ),
        );
      }
    }

    if (AppConfig.hereApiKey.isEmpty) {
      return HereAlertFetchResult(
        data: const SpeedLimitData(
          provider: 'HERE Maps',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'Set HERE_API_KEY via --dart-define',
        ),
      );
    }

    try {
      return await hereApi.fetchHereAlertWithStickySegment(
        lat: lat,
        lng: lng,
        headingDegrees: headingDegrees,
        destLat: destLat,
        destLng: destLng,
      );
    } catch (e) {
      return HereAlertFetchResult(
        data: SpeedLimitData(
          provider: 'HERE Maps',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'HERE API - Error: ${throwableMessageOrToString(e)}',
        ),
      );
    }
  }
}

/// Builds a short backward sticky segment when Edge returns mph but no geometry.
RoadSegment? buildEdgeFallbackStickySegment(
  double lat,
  double lng,
  double? headingDegrees,
  SpeedLimitData data,
) {
  final mph = data.speedLimitMph;
  if (mph == null) return null;
  final h = (headingDegrees != null && headingDegrees.isFinite)
      ? headingDegrees
      : 0.0;
  final backBearing = ((h + 180.0) % 360.0 + 360.0) % 360.0;
  final back = Geo.offsetLatLngMeters(lat, lng, backBearing, 40.0);
  final fwd = Geo.offsetLatLngMeters(lat, lng, h, 130.0);
  final geom = <GeoCoordinate>[
    GeoCoordinate(back.lat, back.lng),
    GeoCoordinate(lat, lng),
    GeoCoordinate(fwd.lat, fwd.lng),
  ];
  final key = (data.segmentKey != null && data.segmentKey!.isNotEmpty)
      ? data.segmentKey!
      : 'edge:${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
  return RoadSegment(
    linkId: key,
    speedLimitMph: mph.toDouble(),
    geometry: geom,
    bearingDeg: h,
    expiresAtMillis: DateTime.now().millisecondsSinceEpoch + 30 * 60 * 1000,
    functionalClass: data.functionalClass,
  );
}
