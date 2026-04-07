import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

/// Android-style [android.location.Location] behavior for the driving pipeline
/// (WGS84 geodesic distance + initial bearing, and speed/bearing availability heuristics for [Position]).
///
/// Distance and bearing: AOSP [android.location.Location.computeDistanceAndBearing]
/// (Vincenty inverse on the WGS84 ellipsoid — same as [Location.distanceBetween] / [Location.bearingTo]).
class AndroidLocationCompat {
  AndroidLocationCompat._();

  static const double _a = 6378137.0;
  static const double _b = 6356752.3142;
  static const double _f = 1 / 298.257223563;
  static const int _maxIterations = 20;

  /// Java [Long.MAX_VALUE] — sentinel for “no prior moderate turn” in heading-invalidation cooldown logic.
  static const int javaLongMaxValue = 9223372036854775807;

  /// [android.location.Location.distanceBetween] (meters).
  static double distanceBetweenMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final out = <double>[0];
    computeDistanceAndBearing(lat1, lon1, lat2, lon2, out);
    return out[0];
  }

  /// [Location.bearingTo] — initial geodesic azimuth in degrees \[0, 360).
  static double bearingToDegrees(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final out = <double>[0, 0];
    computeDistanceAndBearing(lat1, lon1, lat2, lon2, out);
    return out[1];
  }

  /// AOSP [Location.computeDistanceAndBearing]: `out[0]` = m; `out[1]` = bearing1 °; `out[2]` = bearing2 °.
  static void computeDistanceAndBearing(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
    List<double> out,
  ) {
    if (out.isEmpty) {
      throw ArgumentError('results array length must be at least 1');
    }
    if (lat1 == lat2 && lon1 == lon2) {
      out[0] = 0;
      if (out.length > 1) out[1] = 0;
      if (out.length > 2) out[2] = 0;
      return;
    }

    final phi1 = lat1 * math.pi / 180.0;
    final phi2 = lat2 * math.pi / 180.0;
    final l = (lon2 - lon1) * math.pi / 180.0;

    final tanU1 = (1 - _f) * math.tan(phi1);
    final cosU1 = 1 / math.sqrt(1 + tanU1 * tanU1);
    final sinU1 = tanU1 * cosU1;
    final tanU2 = (1 - _f) * math.tan(phi2);
    final cosU2 = 1 / math.sqrt(1 + tanU2 * tanU2);
    final sinU2 = tanU2 * cosU2;

    var lambda = l;
    late double lambdaP;
    var iter = 0;
    var sinSigma = 0.0;
    var cosSigma = 0.0;
    var sigma = 0.0;
    var sinAlpha = 0.0;
    var cosSqAlpha = 0.0;
    var cos2SigmaM = 0.0;

    do {
      final sinLambda = math.sin(lambda);
      final cosLambda = math.cos(lambda);
      sinSigma = math.sqrt(
        (cosU2 * sinLambda) * (cosU2 * sinLambda) +
            (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda) *
                (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda),
      );
      if (sinSigma == 0) {
        out[0] = 0;
        if (out.length > 1) out[1] = 0;
        if (out.length > 2) out[2] = 0;
        return;
      }
      cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda;
      sigma = math.atan2(sinSigma, cosSigma);
      sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma;
      cosSqAlpha = 1 - sinAlpha * sinAlpha;
      cos2SigmaM = cosSigma - 2 * sinU1 * sinU2 / cosSqAlpha;
      if (cosSqAlpha == 0 || cos2SigmaM.isNaN) {
        cos2SigmaM = 0;
      }
      final c = _f / 16 * cosSqAlpha * (4 + _f * (4 - 3 * cosSqAlpha));
      lambdaP = lambda;
      lambda = l +
          (1 - c) *
              _f *
              sinAlpha *
              (sigma +
                  c *
                      sinSigma *
                      (cos2SigmaM +
                          c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)));
      iter++;
    } while ((lambda - lambdaP).abs() > 1e-12 && iter < _maxIterations);

    final uSq = cosSqAlpha * (_a * _a - _b * _b) / (_b * _b);
    final bigA = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)));
    final bigB = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)));
    final deltaSigma = bigB *
        sinSigma *
        (cos2SigmaM +
            bigB /
                4 *
                (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
                    bigB /
                        6 *
                        cos2SigmaM *
                        (-3 + 4 * sinSigma * sinSigma) *
                        (-3 + 4 * cos2SigmaM * cos2SigmaM)));

    final s = _b * bigA * (sigma - deltaSigma);
    out[0] = s;
    if (out.length > 1) {
      var fwdAz = math.atan2(
        cosU2 * math.sin(lambda),
        cosU1 * sinU2 - sinU1 * cosU2 * math.cos(lambda),
      );
      fwdAz = fwdAz * 180 / math.pi;
      out[1] = (fwdAz + 360) % 360;
    }
    if (out.length > 2) {
      var revAz = math.atan2(
        cosU1 * math.sin(lambda),
        -sinU1 * cosU2 + cosU1 * sinU2 * math.cos(lambda),
      );
      revAz = revAz * 180 / math.pi;
      out[2] = (revAz + 360) % 360;
    }
  }

  /// Whether [Position.speed] should be treated as a reported speed (Geolocator vs [Location.hasSpeed]).
  static bool positionHasReportedSpeed(Position p) {
    if (p.isMocked) return true;
    if (p.speedAccuracy > 0) return true;
    if (p.speed != 0) return true;
    return false;
  }

  /// Bearing in degrees when [Position.heading] should be treated as valid (Geolocator vs [Location.hasBearing]).
  static double? positionBearingIfHasBearing(Position p) {
    if (p.isMocked) {
      final h = p.heading;
      if (h.isNaN) return null;
      return h;
    }
    if (p.headingAccuracy > 0) {
      final h = p.heading;
      return h.isNaN ? null : h;
    }
    final h = p.heading;
    if (h.isNaN || h < 0) return null;
    if (h != 0) return h;
    return null;
  }
}
