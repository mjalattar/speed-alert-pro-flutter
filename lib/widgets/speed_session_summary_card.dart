import 'package:flutter/material.dart';

import '../core/constants.dart';

/// Speed / limit summary card: main limit for the selected primary provider + up to two **other**
/// providers listed below (never duplicates the primary in the list).
class SpeedSessionSummaryCard extends StatefulWidget {
  const SpeedSessionSummaryCard({
    super.key,
    required this.primaryProviderLabel,
    required this.isTestingTab,
    required this.isSimulating,
    required this.gpsSpeedMph,
    required this.simulatedSpeedMph,
    required this.limitMph,
    required this.resolvedPrimarySpeedLimitProvider,
    required this.hereMph,
    required this.tomTomMph,
    required this.mapboxMph,
    required this.alertThresholdMph,
    required this.suppressAlertsUnder15Mph,
  });

  /// Label for the main limit column (use [PreferencesManager.resolvedPrimarySpeedLimitProviderDisplayName]).
  final String primaryProviderLabel;

  final bool isTestingTab;
  final bool isSimulating;
  final double gpsSpeedMph;
  final int simulatedSpeedMph;
  final double? limitMph;

  /// [PreferencesManager.resolvedPrimarySpeedLimitProvider] — which vendor is omitted from the list below.
  final int resolvedPrimarySpeedLimitProvider;

  /// HERE mph (main limit when HERE is primary; secondary compare when TomTom/Mapbox is primary).
  final int? hereMph;

  final int? tomTomMph;
  final int? mapboxMph;
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
    final lim = widget.limitMph;
    if (lim == null || lim <= 0) return false;
    if (widget.suppressAlertsUnder15Mph &&
        lim < kSuppressAlertsWhenPostedLimitBelowMph) {
      return false;
    }
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
                            'Speed limit (${widget.primaryProviderLabel})',
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
                ..._secondaryProviderRows(context, fg),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Rows for the providers that are **not** the main (primary) source.
  List<Widget> _secondaryProviderRows(BuildContext context, Color fg) {
    final primary = widget.resolvedPrimarySpeedLimitProvider;
    final rows = <Widget>[];
    if (primary != SpeedLimitPrimaryProvider.here) {
      rows.add(_secondaryProviderRow(context, 'HERE Maps', widget.hereMph, fg));
    }
    if (primary != SpeedLimitPrimaryProvider.tomTom) {
      rows.add(_secondaryProviderRow(context, 'TomTom', widget.tomTomMph, fg));
    }
    if (primary != SpeedLimitPrimaryProvider.mapbox) {
      rows.add(_secondaryProviderRow(context, 'Mapbox', widget.mapboxMph, fg));
    }
    return rows;
  }

  Widget _secondaryProviderRow(
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
