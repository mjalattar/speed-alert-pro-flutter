import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../../core/android_location_compat.dart';
import '../../core/speed_provider_constants.dart';
import '../../models/road_segment.dart';
import '../shared/geo_bearing.dart';
import '../shared/geo_coordinate.dart';

/// Mapbox-only polyline matching (independent of HERE/TomTom implementations).
class MapboxPolylineMatchingOptions {
  const MapboxPolylineMatchingOptions({
    this.horizontalAccuracyMeters,
    this.headingAccuracyDegrees,
    this.vehicleSpeedMps,
    this.edgeMphPerSegment,
  });

  /// Horizontal accuracy (m) from the position fix; larger ⇒ more cross-track slack.
  final double? horizontalAccuracyMeters;

  /// Heading accuracy (deg) from the platform; larger ⇒ heading penalty is down-weighted.
  final double? headingAccuracyDegrees;

  /// Reported speed (m/s) for optional tie-break vs [edgeMphPerSegment].
  final double? vehicleSpeedMps;

  /// Posted limit (mph) per polyline edge, aligned with [geometry.length - 1].
  final List<int?>? edgeMphPerSegment;

  MapboxPolylineMatchingOptions withEdgeMph(List<int?>? edgeMph) => MapboxPolylineMatchingOptions(
        horizontalAccuracyMeters: horizontalAccuracyMeters,
        headingAccuracyDegrees: headingAccuracyDegrees,
        vehicleSpeedMps: vehicleSpeedMps,
        edgeMphPerSegment: edgeMph,
      );

  factory MapboxPolylineMatchingOptions.fromPosition(Position p) {
    final h = p.accuracy;
    final ha = p.headingAccuracy;
    final spd = p.speed;
    return MapboxPolylineMatchingOptions(
      horizontalAccuracyMeters: h > 0 && h.isFinite ? h : null,
      headingAccuracyDegrees: ha > 0 && ha.isFinite ? ha : null,
      vehicleSpeedMps: spd >= 0 && spd.isFinite ? spd : null,
    );
  }
}

/// Cross-track distance, along-polyline distance, and projection helpers for Mapbox Directions geometry.
///
/// [projectOntoPolylineForMatching] / [alongPolylineMetersForMatching] support **heading-weighted**
/// segment choice when [userHeadingDeg] is set — reduces wrong-span picks on parallel roads / forks.
class MapboxCrossTrackGeometry {
  MapboxCrossTrackGeometry._();

  static const earthMPerDegLat = 111320.0;

  /// Extra effective meters added when motion heading disagrees with segment bearing (capped).
  static const double _headingMismatchPenaltyMaxM = 55.0;

  /// When heading accuracy is poor, scale down the heading mismatch penalty (rely more on distance).
  static double _headingPenaltyScale(double? headingAccuracyDeg) {
    if (headingAccuracyDeg == null ||
        !headingAccuracyDeg.isFinite ||
        headingAccuracyDeg <= 0) {
      return 1.0;
    }
    return 1.0 /
        (1.0 + (headingAccuracyDeg / 40.0).clamp(0.0, 1.75));
  }

  /// Cross-track gate: tighter when horizontal accuracy is good; looser when GPS is noisy.
  static double effectiveMaxCrossTrackMeters({
    required double baseMax,
    double? horizontalAccuracyM,
  }) {
    if (horizontalAccuracyM == null ||
        !horizontalAccuracyM.isFinite ||
        horizontalAccuracyM <= 0) {
      return baseMax;
    }
    final a = horizontalAccuracyM.clamp(3.0, 125.0);
    final tight = SpeedProviderConstants
            .polylineMatchTightCrossTrackAccuracyMultiplier *
        a;
    if (tight < baseMax) return tight;
    return (baseMax +
            SpeedProviderConstants.polylineMatchLooseCrossTrackAccuracyCoeff *
                (a - 15.0).clamp(0.0, 120.0))
        .clamp(baseMax, 90.0);
  }

  /// Heading gate: slightly relaxed when platform reports poor heading accuracy.
  static double effectiveMaxHeadingDeltaDeg({
    required double baseDeg,
    double? headingAccuracyDeg,
  }) {
    if (headingAccuracyDeg == null ||
        !headingAccuracyDeg.isFinite ||
        headingAccuracyDeg <= 0) {
      return baseDeg;
    }
    if (headingAccuracyDeg >= 30) {
      return baseDeg + (headingAccuracyDeg - 30) * 0.35;
    }
    return baseDeg;
  }

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

  static MapboxPolylineProjection? projectOntoPolylineDetailed(
    double userLat,
    double userLng,
    List<GeoCoordinate> geometry,
  ) =>
      projectOntoPolylineForMatching(userLat, userLng, geometry, null);

  /// Closest projection with optional **heading-weighted** segment choice: minimizes
  /// cross-track distance plus penalty for heading vs segment bearing mismatch.
  ///
  /// When [userHeadingDeg] is null or not finite, behavior matches pure closest-point
  /// [projectOntoPolylineDetailed] (distance-only).
  ///
  /// [matchingOptions] can supply horizontal/heading accuracy (scales gates and penalty),
  /// plus per-edge posted mph for tie-breaking when two segments score nearly equal.
  static MapboxPolylineProjection? projectOntoPolylineForMatching(
    double userLat,
    double userLng,
    List<GeoCoordinate> geometry,
    double? userHeadingDeg, {
    MapboxPolylineMatchingOptions? matchingOptions,
  }) {
    if (geometry.length < 2) return null;
    final useHeading =
        userHeadingDeg != null && userHeadingDeg.isFinite;
    final headingPenScale =
        _headingPenaltyScale(matchingOptions?.headingAccuracyDegrees);
    final n = geometry.length - 1;
    final tieBreak = matchingOptions != null &&
        matchingOptions.vehicleSpeedMps != null &&
        matchingOptions.vehicleSpeedMps! >=
            SpeedProviderConstants.polylineMatchMinVehicleSpeedMpsForTieBreak &&
        matchingOptions.edgeMphPerSegment != null &&
        matchingOptions.edgeMphPerSegment!.length == n;
    List<double>? segScores;
    List<double>? segCross;
    List<double>? segAlong;
    if (tieBreak) {
      segScores = List<double>.filled(n, double.infinity);
      segCross = List<double>.filled(n, 0);
      segAlong = List<double>.filled(n, 0);
    }
    var bestAlong = 0.0;
    var bestCross = double.infinity;
    var bestScore = double.infinity;
    var bestSeg = 0;
    var cum = 0.0;
    for (var i = 0; i < n; i++) {
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
      final brg = bearingDeg(a.lat, a.lng, b.lat, b.lng);
      double score;
      if (useHeading) {
        final delta =
            smallestBearingDeltaDeg(userHeadingDeg, brg).clamp(0.0, 180.0);
        final penalty = (delta / 90.0).clamp(0.0, 1.75) *
            _headingMismatchPenaltyMaxM *
            headingPenScale;
        score = latDist + penalty;
      } else {
        score = latDist;
      }
      if (segScores != null) {
        segScores[i] = score;
        segCross![i] = latDist;
        segAlong![i] = along;
      }
      if (score < bestScore - 1e-6 ||
          (score - bestScore).abs() <= 1e-6 && latDist < bestCross) {
        bestScore = score;
        bestCross = latDist;
        bestAlong = along;
        bestSeg = i;
      }
      cum += segLen;
    }
    var pickedSeg = bestSeg;
    if (tieBreak) {
      final opts = matchingOptions!;
      final scores = segScores!;
      final alongList = segAlong!;
      final crossList = segCross!;
      const eps = SpeedProviderConstants.polylineMatchTieScoreEpsilonM;
      const mpsToMph = 2.2369362920544;
      final vMph = opts.vehicleSpeedMps! * mpsToMph;
      final edges = opts.edgeMphPerSegment!;
      var bestTieIdx = pickedSeg;
      var bestTieMetric = double.infinity;
      for (var i = 0; i < n; i++) {
        if (scores[i] > bestScore + eps) continue;
        final mph = edges[i];
        if (mph == null) continue;
        final m = (mph - vMph).abs();
        if (m < bestTieMetric) {
          bestTieMetric = m;
          bestTieIdx = i;
        }
      }
      if (bestTieMetric == double.infinity) {
        // No edge mph for tie-break; keep geometric winner.
      } else {
        pickedSeg = bestTieIdx;
        bestAlong = alongList[pickedSeg];
        bestCross = crossList[pickedSeg];
      }
    }
    final a = geometry[pickedSeg];
    final b = geometry[pickedSeg + 1];
    final brg = bearingDeg(a.lat, a.lng, b.lat, b.lng);
    return MapboxPolylineProjection(
      alongMeters: bestAlong,
      crossTrackMeters: bestCross,
      segmentIndex: pickedSeg,
      segmentBearingDeg: brg,
    );
  }

  /// Along-arc length for speed-limit resolution; uses [projectOntoPolylineForMatching] when
  /// [userHeadingDeg] is available.
  static double alongPolylineMetersForMatching(
    double userLat,
    double userLng,
    List<GeoCoordinate> geometry,
    double? userHeadingDeg, {
    MapboxPolylineMatchingOptions? matchingOptions,
  }) {
    final p = projectOntoPolylineForMatching(
      userLat,
      userLng,
      geometry,
      userHeadingDeg,
      matchingOptions: matchingOptions,
    );
    return p?.alongMeters ?? alongPolylineMeters(userLat, userLng, geometry);
  }

  static bool isSectionWalkProjectionValid(
    MapboxPolylineProjection proj,
    List<GeoCoordinate> geometry,
    double? userHeadingDeg, {
    double maxCrossTrackM = 22,
    double maxHeadingDeltaDeg = 55,
    double endBufferM = 28,
    MapboxPolylineMatchingOptions? matchingOptions,
  }) {
    final maxX = effectiveMaxCrossTrackMeters(
      baseMax: maxCrossTrackM,
      horizontalAccuracyM: matchingOptions?.horizontalAccuracyMeters,
    );
    if (proj.crossTrackMeters > maxX) return false;
    final total = polylineLengthMeters(geometry);
    if (total >= 5.0 && proj.alongMeters > total - endBufferM) return false;
    if (userHeadingDeg != null && userHeadingDeg.isFinite) {
      final d = smallestBearingDeltaDeg(userHeadingDeg, proj.segmentBearingDeg);
      final maxHd = effectiveMaxHeadingDeltaDeg(
        baseDeg: maxHeadingDeltaDeg,
        headingAccuracyDeg: matchingOptions?.headingAccuracyDegrees,
      );
      if (d > maxHd) return false;
    }
    return true;
  }

  /// Whether the user position is on the segment polyline within cross-track and heading gates.
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
    final along = userHeadingDeg != null && userHeadingDeg.isFinite
        ? alongPolylineMetersForMatching(
            userLat,
            userLng,
            geom,
            userHeadingDeg,
          )
        : alongPolylineMeters(userLat, userLng, geom);
    if (along > total - endBufferM) return false;
    return true;
  }

  static bool isUserOnPolylineForAlongResolve(
    double userLat,
    double userLng,
    List<GeoCoordinate> geometry, {
    double maxCrossTrackM = 45,
    double pastEndBufferM = 60,
    double? userHeadingDeg,
    MapboxPolylineMatchingOptions? matchingOptions,
  }) {
    if (geometry.length < 2) return false;
    final proj = projectOntoPolylineForMatching(
      userLat,
      userLng,
      geometry,
      userHeadingDeg,
      matchingOptions: matchingOptions,
    );
    if (proj == null) return false;
    final maxCt = effectiveMaxCrossTrackMeters(
      baseMax: maxCrossTrackM,
      horizontalAccuracyM: matchingOptions?.horizontalAccuracyMeters,
    );
    if (proj.crossTrackMeters > maxCt) return false;
    final total = polylineLengthMeters(geometry);
    if (total < 5.0) return true;
    final along = proj.alongMeters;
    return along >= -2.0 && along <= total + pastEndBufferM;
  }
}

class MapboxPolylineProjection {
  MapboxPolylineProjection({
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
