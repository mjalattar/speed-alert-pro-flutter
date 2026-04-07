/// Tunable parameters for the TomTom Snap and Mapbox Directions integrations (separate tuning keys; secondary or non-HERE primary use).
///
/// TomTom: [Synchronous Snap to Roads](https://developer.tomtom.com/snap-to-roads-api/documentation/snap-to-roads-api/synchronous-snap-to-roads)
/// Mapbox: [Directions API](https://docs.mapbox.com/api/navigation/directions/)
class SpeedProviderConstants {
  SpeedProviderConstants._();

  // --- TomTom (Snap to Roads) — gating & along-polyline ---

  static const double tomtomSecondaryNetworkMinDisplacementM = 480.0;
  static const double tomtomSecondaryNetworkMinHeadingChangeDeg = 45.0;
  static const double tomtomSecondaryAlongMaxCrossTrackM = 72.0;
  static const double tomtomSecondaryAlongPastEndBufferM = 90.0;

  static const double tomtomSnapCorridorPointSpacingM = 95.0;
  static const int tomtomSnapCorridorMaxPoints = 14;
  static const int tomtomSnapTimestampMinTotalSec = 3;
  static const int tomtomSnapTimestampMaxTotalSec = 600;
  static const double tomtomSnapOffroadMarginM = 50.0;
  static const double tomtomProjectedPointHeadingTieM = 8.0;
  static const int tomtomSecondaryRouteModelTtlMs = 30 * 60 * 1000;
  static const double tomtomSecondaryVehicleAnchorAlongMaxM = 60.0;

  // --- Mapbox (Directions) — gating & along-polyline ---

  static const double mapboxSecondaryNetworkMinDisplacementM = 480.0;
  static const double mapboxSecondaryNetworkMinHeadingChangeDeg = 45.0;
  static const double mapboxSecondaryAlongMaxCrossTrackM = 70.0;
  static const double mapboxSecondaryAlongPastEndBufferM = 88.0;
  static const int mapboxSecondaryWaypointRadiusM = 58;
  static const int mapboxBearingToleranceDeg = 45;
  static const int mapboxSecondaryRouteModelTtlMs = 25 * 60 * 1000;
  static const double mapboxSecondaryVehicleAnchorAlongMaxM = 50.0;
}
