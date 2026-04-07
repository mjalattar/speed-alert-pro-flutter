/// Mirrors Kotlin [SpeedStabSample] + [SpeedLimitStabilizer].
class SpeedStabSample {
  const SpeedStabSample({this.segmentKey, required this.mph});

  final String? segmentKey;
  final int mph;
}

/// Smooths local HERE speed-limit samples (same rules as Kotlin).
class SpeedLimitStabilizer {
  SpeedLimitStabilizer({int windowSize = defaultWindow})
      : _windowSize = windowSize;

  static const int defaultWindow = 9;

  final int _windowSize;
  final List<SpeedStabSample> _window = [];

  void clear() => _window.clear();

  int pushAndResolve(SpeedStabSample sample) {
    _window.add(sample);
    while (_window.length > _windowSize) {
      _window.removeAt(0);
    }
    return _resolve(sample);
  }

  int _resolve(SpeedStabSample latest) {
    if (_window.length < 3) return latest.mph;

    final keys = _window.map((e) => e.segmentKey).whereType<String>().toList();
    if (keys.length >= 2) {
      final counts = <String, int>{};
      for (final k in keys) {
        counts[k] = (counts[k] ?? 0) + 1;
      }
      String? modeKey;
      var modeCount = 0;
      counts.forEach((k, v) {
        if (v > modeCount) {
          modeCount = v;
          modeKey = k;
        }
      });
      final latestKey = latest.segmentKey;
      if (modeKey != null &&
          latestKey != null &&
          latestKey != modeKey &&
          keys.where((k) => k == latestKey).length == 1 &&
          modeCount >= 3) {
        final stableMphs = _window
            .where((s) => s.segmentKey == modeKey)
            .map((s) => s.mph)
            .toList();
        if (stableMphs.isNotEmpty) {
          stableMphs.sort();
          final stableMedian = stableMphs[stableMphs.length ~/ 2];
          if (latest.mph <= stableMedian - _largeDropTrustDeltaMph) {
            return _spikeFiltered(latest);
          }
          return stableMedian;
        }
      }
    }

    return _spikeFiltered(latest);
  }

  int _spikeFiltered(SpeedStabSample latest) {
    if (_window.length < 4) return latest.mph;
    final list = List<SpeedStabSample>.from(_window);
    final prior = list.sublist(0, list.length - 1).map((e) => e.mph).toList()
      ..sort();
    final baseline = prior[prior.length ~/ 2];
    final needAgree = (prior.length + 1) ~/ 2;
    final agreement =
        prior.where((mph) => (mph - baseline).abs() <= _mphClusterBand).length;

    if (latest.mph <= _lowMphCap && baseline >= _minBaselineForLowReject) {
      return baseline;
    }

    if (latest.mph <= baseline - _largeDropTrustDeltaMph) {
      return latest.mph;
    }

    if (baseline >= _highwayFloorMph &&
        latest.mph >= _midDipLow &&
        latest.mph <= _midDipHigh &&
        latest.mph < baseline - _midDipGap) {
      return baseline;
    }

    if ((latest.mph - baseline).abs() >= _mphSpikeMinDelta &&
        agreement >= needAgree) {
      return baseline;
    }
    return latest.mph;
  }

  static const int _mphSpikeMinDelta = 15;
  static const int _mphClusterBand = 8;
  static const int _lowMphCap = 14;
  static const int _minBaselineForLowReject = 22;
  static const int _highwayFloorMph = 32;
  static const int _midDipLow = 15;
  static const int _midDipHigh = 30;
  static const int _midDipGap = 8;
  static const int _largeDropTrustDeltaMph = 10;
}
