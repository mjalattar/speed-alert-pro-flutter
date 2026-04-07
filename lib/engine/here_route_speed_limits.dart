import 'here_section_speed_model.dart';

/// HERE routing span helpers for local speed-limit parsing.
class HereRouteSpeedLimits {
  HereRouteSpeedLimits._();

  /// Default alert-route lead (m); prefer [kAlertRouteLeadMeters] from constants in callers.
  static const double alertRouteLeadMeters = 1000.0;

  /// First span that carries a speed limit.
  static HereSpan? pickSpeedSpan(List<HereSpan> spans) {
    for (final s in spans) {
      if (s.speedLimitMps != null) return s;
    }
    return null;
  }
}
