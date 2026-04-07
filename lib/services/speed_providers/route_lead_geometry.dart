import '../../core/constants.dart';
import '../../core/geo.dart';

/// Second waypoint for route legs (~[kAlertRouteLeadMeters] along heading). Local geometry only.
String routeLeadDestination(
  double lat,
  double lng,
  double? destLat,
  double? destLng,
  double? headingDegrees,
) {
  if (destLat != null && destLng != null) return '$destLat,$destLng';
  if (headingDegrees != null && headingDegrees.isFinite) {
    final o = Geo.offsetLatLngMeters(lat, lng, headingDegrees, kAlertRouteLeadMeters);
    return '${o.lat},${o.lng}';
  }
  return '${lat + 0.00001},${lng + 0.00001}';
}

/// [routeLeadDestination] without explicit O/D — for debug CSV (lead waypoint).
String routeLeadDestinationForLog(
  double lat,
  double lng,
  double? headingDegrees,
) =>
    routeLeadDestination(lat, lng, null, null, headingDegrees);
