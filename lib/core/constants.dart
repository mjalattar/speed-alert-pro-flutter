/// Mirrors [HereRouteSpeedLimits.ALERT_ROUTE_LEAD_METERS] on Android.
const double kAlertRouteLeadMeters = 1000.0;

/// Mirrors [LOW_SPEED_ALERT_SUPPRESS_BELOW_MPH].
const double kLowSpeedAlertSuppressBelowMph = 15.0;

/// [PreferencesManager] alert run modes.
abstract final class AlertRunMode {
  static const int normal = 0;
  static const int backgroundSound = 1;
  static const int backgroundOverlay = 2;
}

/// UI theme (mirrors [AppThemeMode]).
abstract final class AppThemeMode {
  static const int auto = 0;
  static const int light = 1;
  static const int dark = 2;
}
