import 'here_section_speed_model.dart';

/// Kotlin [HereRouteSpeedLimits] object.
class HereRouteSpeedLimits {
  HereRouteSpeedLimits._();

  /// Kotlin [ALERT_ROUTE_LEAD_METERS] — use [kAlertRouteLeadMeters] from constants in callers.
  static const double alertRouteLeadMeters = 1000.0;

  /// Kotlin [pickSpeedSpan] — first span with a speed limit.
  static HereSpan? pickSpeedSpan(List<HereSpan> spans) {
    for (final s in spans) {
      if (s.speedLimitMps != null) return s;
    }
    return null;
  }
}
