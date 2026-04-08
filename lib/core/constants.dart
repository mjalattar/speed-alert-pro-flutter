/// Virtual route “lead” ahead of the vehicle for routing APIs (HERE / TomTom / Mapbox) (meters).
const double kAlertRouteLeadMeters = 1000.0;

/// Which vendor supplies the **main** speed limit for display + alerts ([PreferencesManager.primarySpeedLimitProvider]).
abstract final class SpeedLimitPrimaryProvider {
  static const int here = 0;
  static const int tomTom = 1;
  static const int mapbox = 2;
}

/// When “suppress alerts under 15 mph” is enabled, overspeed alerts are off while the **posted**
/// main speed limit is below this value (parking lots, etc.), regardless of vehicle speed.
const double kSuppressAlertsWhenPostedLimitBelowMph = 15.0;

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
