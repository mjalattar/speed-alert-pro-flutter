/// Virtual route “lead” ahead of the vehicle for HERE / compare APIs (meters).
const double kAlertRouteLeadMeters = 1000.0;

/// Below this GPS speed (mph), optional suppression of alerts can apply.
const double kLowSpeedAlertSuppressBelowMph = 15.0;

/// [PreferencesManager] alert run modes.
abstract final class AlertRunMode {
  static const int normal = 0;
  static const int backgroundSound = 1;
  static const int backgroundOverlay = 2;
}

/// UI theme mode stored in preferences.
abstract final class AppThemeMode {
  static const int auto = 0;
  static const int light = 1;
  static const int dark = 2;
}
