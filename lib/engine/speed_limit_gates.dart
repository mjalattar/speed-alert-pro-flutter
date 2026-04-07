/// Debounces large raw HERE limit changes (material up/down / high→low drop).
class SpeedLimitMaterialChangeGate {
  SpeedLimitMaterialChangeGate({
    this.materialDeltaMph = defaultMaterialDeltaMph,
    this.lowRawCapMph = defaultLowRawCapMph,
    this.highBaselineMph = highBaselineStrictLowMph,
  });

  static const int defaultMaterialDeltaMph = 15;
  static const int defaultLowRawCapMph = 14;
  static const int highBaselineStrictLowMph = 40;

  static const int confirmationsLargeUp = 1;
  static const int confirmationsLargeDown = 1;
  static const int confirmationsDropLowFromHigh = 3;

  final int materialDeltaMph;
  final int lowRawCapMph;
  final int highBaselineMph;

  int? _pendingRawMph;
  int _consecutiveCount = 0;

  void reset() {
    _pendingRawMph = null;
    _consecutiveCount = 0;
  }

  int _confirmationsNeeded(int rawMph, int current) {
    if (rawMph > current) return confirmationsLargeUp;
    if (rawMph <= lowRawCapMph && current >= highBaselineMph) {
      return confirmationsDropLowFromHigh;
    }
    return confirmationsLargeDown;
  }

  /// Call only when |rawMph − current| ≥ [materialDeltaMph].
  int applyLargeRaw(int rawMph, double? currentDisplayMph) {
    final current = currentDisplayMph?.round();
    if (current == null) {
      reset();
      return rawMph;
    }
    final needed = _confirmationsNeeded(rawMph, current);
    if (rawMph == _pendingRawMph) {
      _consecutiveCount++;
    } else {
      _pendingRawMph = rawMph;
      _consecutiveCount = 1;
    }
    if (_consecutiveCount >= needed) {
      reset();
      return rawMph;
    }
    return current;
  }
}

/// Debounces small upward limit bumps below the material threshold.
class SpeedLimitSmallUpGate {
  SpeedLimitSmallUpGate({
    this.minBumpMph = defaultMinBump,
    this.materialDeltaMph = SpeedLimitMaterialChangeGate.defaultMaterialDeltaMph,
    this.confirmationsRequired = defaultConfirmations,
  });

  static const int defaultMinBump = 5;
  static const int defaultConfirmations = 2;

  final int minBumpMph;
  final int materialDeltaMph;
  final int confirmationsRequired;

  int? _pendingRawMph;
  int _consecutiveCount = 0;

  void reset() {
    _pendingRawMph = null;
    _consecutiveCount = 0;
  }

  int apply(int rawMph, double? currentDisplayMph, int smoothedMph) {
    final current = currentDisplayMph?.round();
    if (current == null) {
      reset();
      return smoothedMph;
    }
    final bump = rawMph - current;
    if (bump < minBumpMph ||
        bump >= materialDeltaMph ||
        rawMph <= current) {
      reset();
      return smoothedMph;
    }
    if (rawMph == _pendingRawMph) {
      _consecutiveCount++;
    } else {
      _pendingRawMph = rawMph;
      _consecutiveCount = 1;
    }
    if (_consecutiveCount >= confirmationsRequired) {
      reset();
      return rawMph;
    }
    return current;
  }
}

/// Debounces moderate downward limit drops below the material threshold.
class SpeedLimitModerateDownGate {
  SpeedLimitModerateDownGate({
    this.minDropMph = defaultMinDrop,
    this.materialDeltaMph = SpeedLimitMaterialChangeGate.defaultMaterialDeltaMph,
    this.confirmationsRequired = defaultConfirmations,
  });

  static const int defaultMinDrop = 5;
  static const int defaultConfirmations = 2;

  final int minDropMph;
  final int materialDeltaMph;
  final int confirmationsRequired;

  int? _pendingRawMph;
  int _consecutiveCount = 0;

  void reset() {
    _pendingRawMph = null;
    _consecutiveCount = 0;
  }

  int apply(int rawMph, double? currentDisplayMph, int smoothedMph) {
    final current = currentDisplayMph?.round();
    if (current == null) {
      reset();
      return smoothedMph;
    }
    final drop = current - rawMph;
    if (rawMph >= current || drop < minDropMph || drop >= materialDeltaMph) {
      reset();
      return smoothedMph;
    }
    if (rawMph == _pendingRawMph) {
      _consecutiveCount++;
    } else {
      _pendingRawMph = rawMph;
      _consecutiveCount = 1;
    }
    if (_consecutiveCount >= confirmationsRequired) {
      reset();
      return rawMph;
    }
    return current;
  }
}

/// Time-based debouncer for committing lower posted limits.
class DownwardLimitDebouncer {
  int? _lastCommitted;
  int? _pending;
  int _pendingSinceMs = 0;
  int _pendingConfirmCount = 0;

  void reset() {
    _lastCommitted = null;
    _pending = null;
    _pendingConfirmCount = 0;
  }

  int commit(int proposed, int nowMs, bool forceImmediate) {
    if (forceImmediate) {
      _lastCommitted = proposed;
      _pending = null;
      _pendingConfirmCount = 0;
      return proposed;
    }
    final last = _lastCommitted;
    if (last == null) {
      _lastCommitted = proposed;
      return proposed;
    }
    if (proposed >= last - _smallDropMph) {
      _lastCommitted = proposed;
      _pending = null;
      _pendingConfirmCount = 0;
      return proposed;
    }
    if (_pending == proposed) {
      _pendingConfirmCount++;
      final elapsed = nowMs - _pendingSinceMs;
      if (_pendingConfirmCount >= _minConfirmSamples ||
          elapsed >= _minConfirmMs) {
        _lastCommitted = proposed;
        _pending = null;
        _pendingConfirmCount = 0;
        return proposed;
      }
    } else {
      _pending = proposed;
      _pendingSinceMs = nowMs;
      _pendingConfirmCount = 1;
    }
    return last;
  }

  static const int _smallDropMph = 10;
  static const int _minConfirmMs = 1400;
  static const int _minConfirmSamples = 2;
}
