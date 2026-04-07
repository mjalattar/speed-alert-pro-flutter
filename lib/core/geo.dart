import 'dart:math' as math;

/// Shared geodesic helpers (bearing = degrees clockwise from north, same as
/// [android.location.Location.getBearing]).
///
/// Kotlin [com.speedalertpro.Geo].
// VERIFIED: 1:1 Logic match with Kotlin (rEarth 6378137.0, asin/atan2 chain).
class Geo {
  Geo._();

  /// Kotlin [Geo.offsetLatLngMeters].
  static ({double lat, double lng}) offsetLatLngMeters(
    double lat,
    double lng,
    double bearingDeg,
    double distanceM,
  ) {
    final br = bearingDeg * math.pi / 180.0;
    const rEarth = 6378137.0;
    final lat1 = lat * math.pi / 180.0;
    final lon1 = lng * math.pi / 180.0;
    final ang = distanceM / rEarth;
    final lat2 = math.asin(
      math.sin(lat1) * math.cos(ang) +
          math.cos(lat1) * math.sin(ang) * math.cos(br),
    );
    final lon2 = lon1 +
        math.atan2(
          math.sin(br) * math.sin(ang) * math.cos(lat1),
          math.cos(ang) - math.sin(lat1) * math.sin(lat2),
        );
    return (lat: lat2 * 180.0 / math.pi, lng: lon2 * 180.0 / math.pi);
  }
}
