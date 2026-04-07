import 'dart:math' as math;

import '../core/android_location_compat.dart';
import '../models/road_segment.dart';
import 'geo_bearing.dart';
import 'geo_coordinate.dart';

/// Mirrors Kotlin [CrossTrackGeometry].
// VERIFIED: 1:1 Logic match with Kotlin ([Location.distanceTo] via [AndroidLocationCompat]).
class CrossTrackGeometry {
  CrossTrackGeometry._();

  static const earthMPerDegLat = 111320.0;

  static double polylineLengthMeters(List<GeoCoordinate> geometry) {
    if (geometry.length < 2) return 0;
    var s = 0.0;
    for (var i = 0; i < geometry.length - 1; i++) {
      final a = geometry[i];
      final b = geometry[i + 1];
      s += AndroidLocationCompat.distanceBetweenMeters(a.lat, a.lng, b.lat, b.lng);
    }
    return s;
  }

  static double alongPolylineMeters(
    double userLat,
    double userLng,
    List<GeoCoordinate> geometry,
  ) {
    if (geometry.length < 2) return 0;
    var bestAlong = 0.0;
    var bestLat = double.infinity;
    var cum = 0.0;
    for (var i = 0; i < geometry.length - 1; i++) {
      final a = geometry[i];
      final b = geometry[i + 1];
      final segLen =
          AndroidLocationCompat.distanceBetweenMeters(a.lat, a.lng, b.lat, b.lng);
      if (segLen < 0.5) continue;
      final proj = projectOntoSegmentMeters(
        userLat, userLng, a.lat, a.lng, b.lat, b.lng,
      );
      final cLat = proj.$2;
      final cLng = proj.$3;
      final latDist = AndroidLocationCompat.distanceBetweenMeters(
        userLat, userLng, cLat, cLng,
      );
      final along = cum + proj.$1 * segLen;
      if (latDist < bestLat) {
        bestLat = latDist;
        bestAlong = along;
      }
      cum += segLen;
    }
    return bestAlong;
  }

  static double crossTrackDistanceMeters(
    double userLat,
    double userLng,
    List<GeoCoordinate> geometry,
  ) {
    if (geometry.length < 2) return double.infinity;
    var best = double.infinity;
    for (var i = 0; i < geometry.length - 1; i++) {
      final a = geometry[i];
      final b = geometry[i + 1];
      final proj = projectOntoSegmentMeters(
        userLat, userLng, a.lat, a.lng, b.lat, b.lng,
      );
      final d = AndroidLocationCompat.distanceBetweenMeters(
        userLat, userLng, proj.$2, proj.$3,
      );
      if (d < best) best = d;
    }
    return best;
  }

  /// Returns (t, cLat, cLng).
  static (double, double, double) projectOntoSegmentMeters(
    double pLat,
    double pLng,
    double aLat,
    double aLng,
    double bLat,
    double bLng,
  ) {
    final lat0 = math.pi * (aLat + bLat) / 360.0;
    final scale = math.cos(lat0) * earthMPerDegLat;
    final ax = aLng * scale;
    final bx = bLng * scale;
    final px = pLng * scale;
    final ay = aLat * earthMPerDegLat;
    final by = bLat * earthMPerDegLat;
    final py = pLat * earthMPerDegLat;
    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;
    final ab2 = abx * abx + aby * aby;
    final t = ab2 < 1e-9
        ? 0.0
        : ((apx * abx + apy * aby) / ab2).clamp(0.0, 1.0);
    final cx = ax + t * abx;
    final cy = ay + t * aby;
    final cLat = cy / earthMPerDegLat;
    final cLng = cx / scale;
    return (t, cLat, cLng);
  }

  static PolylineProjection? projectOntoPolylineDetailed(
    double userLat,
    double userLng,
    List<GeoCoordinate> geometry,
  ) {
    if (geometry.length < 2) return null;
    var bestAlong = 0.0;
    var bestLat = double.infinity;
    var bestSeg = 0;
    var cum = 0.0;
    for (var i = 0; i < geometry.length - 1; i++) {
      final a = geometry[i];
      final b = geometry[i + 1];
      final segLen =
          AndroidLocationCompat.distanceBetweenMeters(a.lat, a.lng, b.lat, b.lng);
      if (segLen < 0.5) continue;
      final proj = projectOntoSegmentMeters(
        userLat, userLng, a.lat, a.lng, b.lat, b.lng,
      );
      final t = proj.$1;
      final cLat = proj.$2;
      final cLng = proj.$3;
      final latDist = AndroidLocationCompat.distanceBetweenMeters(
        userLat, userLng, cLat, cLng,
      );
      final along = cum + t * segLen;
      if (latDist < bestLat) {
        bestLat = latDist;
        bestAlong = along;
        bestSeg = i;
      }
      cum += segLen;
    }
    final a = geometry[bestSeg];
    final b = geometry[bestSeg + 1];
    final brg = bearingDeg(a.lat, a.lng, b.lat, b.lng);
    return PolylineProjection(
      alongMeters: bestAlong,
      crossTrackMeters: bestLat,
      segmentIndex: bestSeg,
      segmentBearingDeg: brg,
    );
  }

  static bool isSectionWalkProjectionValid(
    PolylineProjection proj,
    List<GeoCoordinate> geometry,
    double? userHeadingDeg, {
    double maxCrossTrackM = 22,
    double maxHeadingDeltaDeg = 55,
    double endBufferM = 28,
  }) {
    if (proj.crossTrackMeters > maxCrossTrackM) return false;
    final total = polylineLengthMeters(geometry);
    if (total >= 5.0 && proj.alongMeters > total - endBufferM) return false;
    if (userHeadingDeg != null && userHeadingDeg.isFinite) {
      final d = smallestBearingDeltaDeg(userHeadingDeg, proj.segmentBearingDeg);
      if (d > maxHeadingDeltaDeg) return false;
    }
    return true;
  }

  /// Mirrors Kotlin [CrossTrackGeometry.isUserOnSegment].
  static bool isUserOnSegment(
    double userLat,
    double userLng,
    RoadSegment segment,
    double? userHeadingDeg, {
    double maxCrossTrackM = 20,
    double maxHeadingDeltaDeg = 45,
    double endBufferM = 25,
  }) {
    final geom = segment.geometry;
    if (geom.length < 2) return false;
    final ct = crossTrackDistanceMeters(userLat, userLng, geom);
    if (ct > maxCrossTrackM) return false;
    if (userHeadingDeg != null &&
        userHeadingDeg.isFinite &&
        segment.bearingDeg.isFinite) {
      final d = smallestBearingDeltaDeg(userHeadingDeg, segment.bearingDeg);
      if (d > maxHeadingDeltaDeg) return false;
    }
    final total = polylineLengthMeters(geom);
    if (total < 5.0) return true;
    final along = alongPolylineMeters(userLat, userLng, geom);
    if (along > total - endBufferM) return false;
    return true;
  }

  static bool isUserOnPolylineForAlongResolve(
    double userLat,
    double userLng,
    List<GeoCoordinate> geometry, {
    double maxCrossTrackM = 45,
    double pastEndBufferM = 60,
  }) {
    if (geometry.length < 2) return false;
    final ct = crossTrackDistanceMeters(userLat, userLng, geometry);
    if (ct > maxCrossTrackM) return false;
    final total = polylineLengthMeters(geometry);
    if (total < 5.0) return true;
    final along = alongPolylineMeters(userLat, userLng, geometry);
    return along >= -2.0 && along <= total + pastEndBufferM;
  }
}

class PolylineProjection {
  PolylineProjection({
    required this.alongMeters,
    required this.crossTrackMeters,
    required this.segmentIndex,
    required this.segmentBearingDeg,
  });
  final double alongMeters;
  final double crossTrackMeters;
  final int segmentIndex;
  final double segmentBearingDeg;
}
