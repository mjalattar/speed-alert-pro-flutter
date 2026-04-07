import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../core/android_location_compat.dart';

/// Short FIFO of recent fixes for trajectory bearing (device bearing when available, else geodesic).
class GpsTrajectoryBuffer {
  GpsTrajectoryBuffer({this.capacity = 5});

  final int capacity;

  final List<_Sample> _samples = [];

  void add(Position location, double effectiveSpeedMps) {
    final b = AndroidLocationCompat.positionBearingIfHasBearing(location);
    _samples.add(
      _Sample(
        lat: location.latitude,
        lng: location.longitude,
        bearingDeg: b,
        speedMps: effectiveSpeedMps < 0 ? 0.0 : effectiveSpeedMps,
      ),
    );
    while (_samples.length > capacity) {
      _samples.removeAt(0);
    }
  }

  void clear() => _samples.clear();

  /// Bearing (deg clockwise from N) from first→last moving sample; else last fix bearing.
  double? bearingDegreesForMatching() {
    if (_samples.isEmpty) return null;
    if (_samples.length < 2) {
      return _samples.last.bearingDeg;
    }
    final moving = _samples.where((s) => s.speedMps >= _minSpeedMpsForPath).toList();
    if (moving.length >= 2) {
      final a = moving.first;
      final b = moving.last;
      final dist = AndroidLocationCompat.distanceBetweenMeters(
        a.lat,
        a.lng,
        b.lat,
        b.lng,
      );
      if (dist >= _minPathMeters) {
        return AndroidLocationCompat.bearingToDegrees(
          a.lat,
          a.lng,
          b.lat,
          b.lng,
        );
      }
    }
    for (var i = _samples.length - 1; i >= 0; i--) {
      final s = _samples[i];
      if (s.speedMps >= _minSpeedMpsForPath && s.bearingDeg != null) {
        return s.bearingDeg;
      }
    }
    return _samples.last.bearingDeg;
  }

  /// Circular mean of recent reported bearings (when ≥2 samples have bearings) — dampens GPS
  /// heading jitter for polyline matching. Falls back to [bearingDegreesForMatching].
  double? bearingDegreesSmoothedForMatching() {
    final bearings = <double>[];
    for (var i = _samples.length - 1;
        i >= 0 && bearings.length < 4;
        i--) {
      final b = _samples[i].bearingDeg;
      if (b != null && b.isFinite) bearings.add(b);
    }
    if (bearings.length >= 2) {
      var sx = 0.0;
      var sy = 0.0;
      for (final b in bearings) {
        final rad = b * math.pi / 180.0;
        sx += math.sin(rad);
        sy += math.cos(rad);
      }
      if (sx.abs() + sy.abs() > 1e-9) {
        final ang = math.atan2(sx, sy) * 180.0 / math.pi;
        return (ang + 360.0) % 360.0;
      }
    }
    return bearingDegreesForMatching();
  }

  static const double _minSpeedMpsForPath = 1.0;
  static const double _minPathMeters = 8.0;
}

class _Sample {
  const _Sample({
    required this.lat,
    required this.lng,
    this.bearingDeg,
    required this.speedMps,
  });

  final double lat;
  final double lng;
  final double? bearingDeg;
  final double speedMps;
}
