/// Time-based debouncer for committing lower posted limits from **HERE** only.
///
/// TomTom/Mapbox primary limits do not use this; they pass raw/display through without delay.
class HereDownwardLimitDebouncer {
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
