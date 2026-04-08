/// Apply payload when a HERE or Remote primary tick resolves a limit from route geometry.
class RoutePrimaryApplySnapshot {
  const RoutePrimaryApplySnapshot({
    required this.rawMph,
    required this.segmentKey,
    required this.functionalClass,
    required this.resolvePath,
  });

  final int rawMph;
  final String? segmentKey;
  final int? functionalClass;
  final String resolvePath;
}

/// Result of attempting section-walk resolution before sticky / network fetch.
sealed class RoutePrimarySectionWalkResult {}

/// Section-walk produced a limit; caller should apply and stop the tick.
class RoutePrimarySectionWalkStop extends RoutePrimarySectionWalkResult {
  RoutePrimarySectionWalkStop(this.apply);
  final RoutePrimaryApplySnapshot apply;
}

/// Projection invalid — caller should clear section model and continue.
class RoutePrimarySectionWalkInvalidate extends RoutePrimarySectionWalkResult {}

/// Valid projection but no mph, or no usable model — caller continues to sticky / fetch.
class RoutePrimarySectionWalkContinue extends RoutePrimarySectionWalkResult {}
