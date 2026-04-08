import '../config/app_config.dart';
import '../core/constants.dart' show SpeedLimitPrimaryProvider;
import '../models/route_alert_fetch_result.dart';
import '../models/speed_limit_data.dart';
import 'mapbox/speed_provider.dart';
import 'tomtom/speed_provider.dart';
import 'here/here_alert_route_provider.dart';
import 'remote/remote_alert_route_provider.dart';
import 'preferences_manager.dart';

/// Aggregates speed-limit rows for map / progressive UI. The **primary** vendor ([PreferencesManager.resolvedPrimarySpeedLimitProvider])
/// matches [LocationProcessor] alerts; others are secondary columns from sticky cache (no extra HTTP here for TomTom/Mapbox).
class SpeedLimitAggregator {
  SpeedLimitAggregator({
    required this.preferencesManager,
    required this.here,
    required this.remote,
    required this.tomTom,
    required this.mapbox,
  });

  final PreferencesManager preferencesManager;
  final HereAlertRouteProvider here;
  final RemoteAlertRouteProvider remote;
  final TomTomSpeedProvider tomTom;
  final MapboxSpeedProvider mapbox;

  SpeedLimitData _disabledProviderData(String provider) => SpeedLimitData(
        provider: provider,
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Disabled in settings',
      );

  SpeedLimitData _cacheMissPlaceholder(String provider) => SpeedLimitData(
        provider: provider,
        speedLimitMph: null,
        confidence: ConfidenceLevel.low,
        source: 'Not fetched yet',
      );

  /// HERE, Remote (when built), TomTom, and Mapbox rows. **Primary** row is flagged for UI emphasis.
  ///
  /// TomTom/Mapbox are served from the sticky cache only (pipeline fills the cache while driving).
  Future<void> fetchAllSpeedLimitsProgressive({
    required double latitude,
    required double longitude,
    double? destinationLat,
    double? destinationLng,
    double? headingDegrees,
    bool includeHere = true,
    required void Function(SpeedLimitData data, {required bool isPrimaryProviderRow}) onEach,
  }) async {
    final primary = preferencesManager.resolvedPrimarySpeedLimitProvider;

    if (includeHere) {
      final data = !preferencesManager.isHereApiEnabled
          ? _disabledProviderData('HERE Maps')
          : await here.fetchMapsSpeedLimit(
              lat: latitude,
              lng: longitude,
              headingDegrees: headingDegrees,
              destLat: destinationLat,
              destLng: destinationLng,
            );
      onEach(
        data,
        isPrimaryProviderRow: primary == SpeedLimitPrimaryProvider.here,
      );
    }

    if (AppConfig.useRemoteHere) {
      final data = !preferencesManager.isRemoteApiEnabled
          ? _disabledProviderData('Remote')
          : await remote.fetchMapsSpeedLimit(
              lat: latitude,
              lng: longitude,
              headingDegrees: headingDegrees,
              destLat: destinationLat,
              destLng: destinationLng,
            );
      onEach(
        data,
        isPrimaryProviderRow: primary == SpeedLimitPrimaryProvider.remote,
      );
    }

    final ttData = !preferencesManager.isTomTomApiEnabled
        ? _disabledProviderData('TomTom')
        : (tomTom.peekCached() ?? _cacheMissPlaceholder('TomTom'));
    onEach(ttData, isPrimaryProviderRow: primary == SpeedLimitPrimaryProvider.tomTom);

    final mbData = !preferencesManager.isMapboxApiEnabled
        ? _disabledProviderData('Mapbox')
        : (mapbox.peekCached() ?? _cacheMissPlaceholder('Mapbox'));
    onEach(mbData, isPrimaryProviderRow: primary == SpeedLimitPrimaryProvider.mapbox);
  }

  /// Secondary HERE compare (HERE REST only — not Remote).
  Future<SpeedLimitData> fetchHereMapsOnly({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) =>
      here.fetchMapsSpeedLimit(
        lat: lat,
        lng: lng,
        headingDegrees: headingDegrees,
        destLat: destLat,
        destLng: destLng,
      );

  /// Secondary Remote compare (Supabase Edge — same as alert `kind: alert`).
  Future<SpeedLimitData> fetchRemoteMapsOnly({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) =>
      remote.fetchMapsSpeedLimit(
        lat: lat,
        lng: lng,
        headingDegrees: headingDegrees,
        destLat: destLat,
        destLng: destLng,
      );

  Future<RouteAlertFetchResult> fetchHereForAlerts({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) =>
      here.fetchForAlerts(
        lat: lat,
        lng: lng,
        headingDegrees: headingDegrees,
        destLat: destLat,
        destLng: destLng,
      );

  Future<RouteAlertFetchResult> fetchRemoteForAlerts({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) =>
      remote.fetchForAlerts(
        lat: lat,
        lng: lng,
        headingDegrees: headingDegrees,
        destLat: destLat,
        destLng: destLng,
      );
}
