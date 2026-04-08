import '../../config/app_config.dart';
import '../../core/throwable_message.dart';
import '../../models/route_alert_fetch_result.dart';
import '../../models/speed_limit_data.dart';
import 'api_service.dart';
import '../preferences_manager.dart';

/// HERE REST Router on device — map and alert surfaces only (no Remote / Edge).
class HereAlertRouteProvider {
  HereAlertRouteProvider({
    required this.preferencesManager,
    required this.hereApi,
  });

  final PreferencesManager preferencesManager;
  final HereApiService hereApi;

  /// Map / non-driving: HERE REST only.
  Future<SpeedLimitData> fetchMapsSpeedLimit({
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

  /// HERE Router (`v8/routes` on device).
  Future<RouteAlertFetchResult> fetchForAlerts({
    required double lat,
    required double lng,
    double? headingDegrees,
    double? destLat,
    double? destLng,
  }) async {
    if (!preferencesManager.isHereApiEnabled) {
      return RouteAlertFetchResult(
        data: const SpeedLimitData(
          provider: 'HERE Maps',
          speedLimitMph: null,
          confidence: ConfidenceLevel.low,
          source: 'Disabled in settings',
        ),
      );
    }

    if (AppConfig.hereApiKey.isEmpty) {
      return RouteAlertFetchResult(
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
      return RouteAlertFetchResult(
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
