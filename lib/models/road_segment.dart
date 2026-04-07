import '../engine/geo_coordinate.dart';

/// Cached road segment for sticky speed-limit display (HERE routing polyline or Edge synthetic corridor).
///
/// Spec mapping: [linkId] = span / stable key, [speedLimitMph] = posted limit, [geometry] = polyline,
/// [bearingDeg] = average road heading, [expiresAtMillis] = cache expiry (~30 min).
///
/// Cached HERE sticky segment with expiry wall time.
class RoadSegment {
  RoadSegment({
    required this.linkId,
    required this.speedLimitMph,
    required this.geometry,
    required this.bearingDeg,
    required this.expiresAtMillis,
    this.functionalClass,
  });

  final String linkId;
  final double speedLimitMph;
  final List<GeoCoordinate> geometry;
  final double bearingDeg;
  final int expiresAtMillis;
  final int? functionalClass;

  /// Whether [expiresAtMillis] is reached (defaults to `DateTime.now()` if [nowMillis] omitted).
  bool isExpired([int? nowMillis]) =>
      (nowMillis ?? DateTime.now().millisecondsSinceEpoch) >= expiresAtMillis;
}
