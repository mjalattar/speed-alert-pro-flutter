import 'package:flutter/material.dart';

import '../core/constants.dart';

/// Speed / limit summary card with compare columns and speeding flash animation.
class SpeedSessionSummaryCard extends StatefulWidget {
  const SpeedSessionSummaryCard({
    super.key,
    required this.isTestingTab,
    required this.isSimulating,
    required this.gpsSpeedMph,
    required this.simulatedSpeedMph,
    required this.limitMph,
    required this.tomTomCompareMph,
    required this.mapboxCompareMph,
    required this.alertThresholdMph,
    required this.suppressAlertsUnder15Mph,
  });

  final bool isTestingTab;
  final bool isSimulating;
  final double gpsSpeedMph;
  final int simulatedSpeedMph;
  final double? limitMph;
  final int? tomTomCompareMph;
  final int? mapboxCompareMph;
  final int alertThresholdMph;
  final bool suppressAlertsUnder15Mph;

  @override
  State<SpeedSessionSummaryCard> createState() => _SpeedSessionSummaryCardState();
}

class _SpeedSessionSummaryCardState extends State<SpeedSessionSummaryCard>
    with SingleTickerProviderStateMixin {
  /// Tolerance for floating-point speeding comparison.
  static const double _speedingEpsilon = 0.0001;

  /// Speeding flash: 1500ms reverse repeat.
  static const Duration _flashDuration = Duration(milliseconds: 1500);

  late final AnimationController _flashCtl;

  @override
  void initState() {
    super.initState();
    _flashCtl = AnimationController(vsync: this, duration: _flashDuration);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncFlashAnimation(_isSpeeding());
    });
  }

  @override
  void didUpdateWidget(covariant SpeedSessionSummaryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFlashAnimation(_isSpeeding());
  }

  void _syncFlashAnimation(bool speeding) {
    if (speeding) {
      if (!_flashCtl.isAnimating) {
        _flashCtl.repeat(reverse: true);
      }
    } else {
      _flashCtl
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _flashCtl.dispose();
    super.dispose();
  }

  /// Display speed: simulated mph on Testing+sim, zero on Testing idle, else live GPS mph.
  double _speedMphForCard() {
    if (widget.isTestingTab) {
      if (widget.isSimulating) {
        return widget.simulatedSpeedMph.toDouble();
      }
      return 0;
    }
    return widget.gpsSpeedMph;
  }

  bool _isSpeeding() {
    final lim = widget.limitMph ?? 0;
    final suppressLow = widget.suppressAlertsUnder15Mph &&
        !widget.isTestingTab &&
        widget.gpsSpeedMph < kLowSpeedAlertSuppressBelowMph;
    if (suppressLow) return false;
    if (lim <= 0) return false;
    final speed = _speedMphForCard();
    return speed > lim + widget.alertThresholdMph - _speedingEpsilon;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final speedLabel = widget.isTestingTab ? 'Simulated speed' : 'Current speed';
    final speedValueText = widget.isTestingTab
        ? (widget.isSimulating ? '${widget.simulatedSpeedMph} mph' : '—')
        : '${widget.gpsSpeedMph.round()} mph';

    final lim = widget.limitMph ?? 0;
    final limitText = lim > 0 ? '${lim.round()} mph' : '-- mph';

    final baseCard = scheme.surfaceContainerHighest;
    final speedAlert = scheme.error;
    final baseFg = scheme.onSurface;
    final alertFg = scheme.onError;

    return AnimatedBuilder(
      animation: _flashCtl,
      builder: (context, _) {
        final speeding = _isSpeeding();
        final t = speeding ? _flashCtl.value : 0.0;
        final bg = Color.lerp(baseCard, speedAlert, t)!;
        final fg = Color.lerp(baseFg, alertFg, t)!;

        return Card(
          color: bg,
          elevation: 8,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            speedLabel,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            speedValueText,
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: fg,
                                ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'Speed limit (HERE)',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg),
                            textAlign: TextAlign.end,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            limitText,
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: fg,
                                ),
                            textAlign: TextAlign.end,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _providerRow(context, 'TomTom (compare)', widget.tomTomCompareMph, fg),
                _providerRow(context, 'Mapbox (compare)', widget.mapboxCompareMph, fg),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _providerRow(
    BuildContext context,
    String label,
    int? mph,
    Color fg,
  ) {
    final hasMph = mph != null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: fg.withValues(alpha: 0.7),
                ),
          ),
          Text(
            hasMph ? '$mph mph' : 'N/A',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: hasMph ? fg.withValues(alpha: 0.8) : fg.withValues(alpha: 0.5),
                ),
          ),
        ],
      ),
    );
  }
}
