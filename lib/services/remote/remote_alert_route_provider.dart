import '../../config/app_config.dart';
import '../../core/geo.dart';
import '../../core/throwable_message.dart';
import '../../engine/shared/geo_coordinate.dart';
import '../../models/road_segment.dart';
import '../../models/route_alert_fetch_result.dart';
import '../../models/speed_limit_data.dart';
import 'edge_function_client.dart';
import '../preferences_manager.dart';

/// Remote (Supabase Edge) — map and alert surfaces only (no HERE REST on device).
class RemoteAlertRouteProvider {
  RemoteAlertRouteProvider({
    required this.preferencesManager,
    this.edgeClient,
  });

  final PreferencesManager preferencesManager;
  final RemoteEdgeFunctionClient? edgeClient;

  Future<SpeedLimitData> fetchMapsSpeedLimit({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) async {
    if (!AppConfig.useRemoteHere) {
      return const SpeedLimitData(
        provider: 'Remote',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Remote not configured in build',
      );
    }
    if (!preferencesManager.isRemoteApiEnabled) {
      return const SpeedLimitData(
        provider: 'Remote',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Disabled in settings',
      );
    }
    final edge = edgeClient;
    if (edge == null) {
      return const SpeedLimitData(
        provider: 'Remote',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Remote unavailable',
      );
    }
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
        provider: 'Remote',
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Remote - Error: ${throwableMessageOrToString(e)}',
      );
    }
  }

  Future<RouteAlertFetchResult> fetchForAlerts({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) async {
    if (!AppConfig.useRemoteHere) {
      return RouteAlertFetchResult(
        data: const SpeedLimitData(
          provider: 'Remote',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'Remote not configured in build',
        ),
      );
    }
    if (!preferencesManager.isRemoteApiEnabled) {
      return RouteAlertFetchResult(
        data: const SpeedLimitData(
          provider: 'Remote',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'Disabled in settings',
        ),
      );
    }
    final edge = edgeClient;
    if (edge == null) {
      return RouteAlertFetchResult(
        data: const SpeedLimitData(
          provider: 'Remote',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'Remote unavailable',
        ),
      );
    }

    try {
      final data = await edge.fetchAlertSpeedMph(
        lat: lat,
        lng: lng,
        destLat: destLat,
        destLng: destLng,
        headingDegrees: headingDegrees,
      );
      final sticky = buildRemoteFallbackStickySegment(
        lat,
        lng,
        headingDegrees,
        data,
      );
      return RouteAlertFetchResult(data: data, stickySegment: sticky);
    } catch (e) {
      return RouteAlertFetchResult(
        data: SpeedLimitData(
          provider: 'Remote',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'Remote - Error: ${throwableMessageOrToString(e)}',
        ),
      );
    }
  }
}

/// Short backward sticky segment when Remote returns mph but no geometry.
RoadSegment? buildRemoteFallbackStickySegment(
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
      : 'remote:${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
  return RoadSegment(
    linkId: key,
    speedLimitMph: mph.toDouble(),
    geometry: geom,
    bearingDeg: h,
    expiresAtMillis: DateTime.now().millisecondsSinceEpoch + 30 * 60 * 1000,
    functionalClass: data.functionalClass,
  );
}
