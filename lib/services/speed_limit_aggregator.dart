import '../config/app_config.dart';
import '../core/geo.dart';
import '../engine/geo_coordinate.dart';
import '../models/here_alert_fetch_result.dart';
import '../models/road_segment.dart';
import '../models/speed_limit_data.dart';
import 'compare_providers_service.dart';
import 'here_api_service.dart';
import 'here_edge_function_client.dart';
import 'preferences_manager.dart';

/// Returns [Exception.message] when present, otherwise [Object.toString].
String throwableMessageOrToString(Object e) {
  try {
    final m = (e as dynamic).message;
    if (m != null) return m.toString();
  } catch (_) {}
  return e.toString();
}

/// Aggregates speed-limit data. **HERE Maps is the only producer for driving alerts** ([LocationProcessor]).
///
/// TomTom and Mapbox are **comparison consumers** only — [CompareProvidersService] + [AnnotationSectionSpeedModel]
/// along-polyline tiling. Their [SpeedLimitData] rows must never be treated as the posted limit for
/// [LocationProcessor.onSpeedUpdate] / audible alerts; only HERE-derived values flowing through
/// [fetchHereForAlerts] and the processor’s debounced resolution establish that limit.
///
/// [fetchAllSpeedLimitsProgressive] never calls TomTom/Mapbox over the network; it replays the compare cache
/// filled by [LocationProcessor] (triple-lock fetch architecture).
class SpeedLimitAggregator {
  SpeedLimitAggregator({
    required this.preferencesManager,
    required this.hereApi,
    this.hereEdgeFunctionClient,
    required this.compare,
  });

  final PreferencesManager preferencesManager;
  final HereApiService hereApi;
  final HereEdgeFunctionClient? hereEdgeFunctionClient;
  final CompareProvidersService compare;

  /// Returns the Edge client when remote speed API is enabled, else null.
  HereEdgeFunctionClient? _edgeOrNull() {
    if (!preferencesManager.useRemoteSpeedApi) return null;
    return hereEdgeFunctionClient;
  }

  SpeedLimitData _disabledProviderData(String provider) => SpeedLimitData(
        provider: provider,
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Disabled in settings',
      );

  SpeedLimitData _compareCacheMissPlaceholder(String provider) => SpeedLimitData(
        provider: provider,
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Not fetched yet',
      );

  /// Streams HERE (optional), then TomTom and Mapbox rows for progressive UI.
  ///
  /// Delivers rows in order: optional **primary HERE** (live [fetchHereMapsOnly]), then **TomTom** and **Mapbox**
  /// from the compare sticky cache only (no compare HTTP).
  ///
  /// Use [isPrimaryHereProducer] to separate the authoritative HERE row from comparison-only rows.
  Future<void> fetchAllSpeedLimitsProgressive({
    required double latitude,
    required double longitude,
    double? destinationLat,
    double? destinationLng,
    double? headingDegrees,
    bool includeHere = true,
    required void Function(SpeedLimitData data, {required bool isPrimaryHereProducer}) onEach,
  }) async {
    if (includeHere) {
      final data = !preferencesManager.isHereApiEnabled
          ? _disabledProviderData('HERE Maps')
          : await fetchHereMapsOnly(
              lat: latitude,
              lng: longitude,
              headingDegrees: headingDegrees,
              destLat: destinationLat,
              destLng: destinationLng,
            );
      onEach(data, isPrimaryHereProducer: true);
    }

    final ttData = !preferencesManager.isTomTomApiEnabled
        ? _disabledProviderData('TomTom')
        : (compare.peekCachedTomTomCompare() ?? _compareCacheMissPlaceholder('TomTom'));
    final mbData = !preferencesManager.isMapboxApiEnabled
        ? _disabledProviderData('Mapbox')
        : (compare.peekCachedMapboxCompare() ?? _compareCacheMissPlaceholder('Mapbox'));
    onEach(ttData, isPrimaryHereProducer: false);
    onEach(mbData, isPrimaryHereProducer: false);
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

  /// **Sole** network entry used by [LocationProcessor] for alert/sticky/section-walk resolution
  /// ([HereAlertFetchResult]). TomTom/Mapbox are not invoked here.
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
