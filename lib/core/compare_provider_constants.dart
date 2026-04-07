/// Tunable TomTom / Mapbox compare request parameters.
///
/// Adjust here to trade off wrong-road snaps vs failed matches; values align with
/// vendor defaults where noted.
class CompareProviderConstants {
  CompareProviderConstants._();

  /// TomTom Snap to Roads: max distance (m) from a road for an input point to be
  /// considered on-road (API default 50).
  static const double tomtomSnapOffroadMarginM = 50.0;

  /// Mapbox Directions: waypoint snap radius (m) per coordinate (`radiuses` query).
  static const int mapboxWaypointRadiusM = 50;

  /// Mapbox Directions: `bearings` second value — allowed deviation in degrees.
  static const int mapboxBearingToleranceDeg = 45;

  /// When several TomTom [projectedPoints] are within this distance (m) of the
  /// vehicle, use [headingDegrees] vs road segment bearing to pick among them.
  static const double tomtomProjectedPointHeadingTieM = 8.0;
}
