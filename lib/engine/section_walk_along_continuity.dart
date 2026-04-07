import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

/// Mirrors Kotlin [SectionWalkAlongContinuity].
class SectionWalkAlongContinuity {
  double? _lastAlongM;
  int? _lastTimeMs;

  void reset() {
    _lastAlongM = null;
    _lastTimeMs = null;
  }

  double clampAlong(double alongMeters, Position location) {
    final now = location.timestamp.millisecondsSinceEpoch;
    final lastMs = _lastTimeMs;
    final dtMs = lastMs == null ? 1 << 62 : now - lastMs;
    if (dtMs > _staleMs) {
      _lastAlongM = alongMeters;
      _lastTimeMs = now;
      return alongMeters;
    }
    final prev = _lastAlongM;
    if (prev == null) {
      _lastAlongM = alongMeters;
      _lastTimeMs = now;
      return alongMeters;
    }
    final dtSec = (dtMs < 1 ? 1 : dtMs) / 1000.0;
    final speedMps = location.speed >= 0 ? location.speed : 0.0;
    final maxReasonableMps = math.max(speedMps * 2.5 + 3.0, _minMaxStepMps);
    final maxStep = maxReasonableMps * dtSec + _marginM;
    final delta = alongMeters - prev;
    final clamped =
        delta.abs() <= maxStep ? alongMeters : prev + maxStep * delta.sign;
    _lastAlongM = clamped;
    _lastTimeMs = now;
    return clamped;
  }

  static const int _staleMs = 8000;
  static const double _minMaxStepMps = 35.0;
  static const double _marginM = 20.0;
}
