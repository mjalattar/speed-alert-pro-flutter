/// Kotlin [SpeedDebugLogSession].
enum SpeedDebugLogSession {
  none,
  simulation,
  driving,
}

/// Mutable active session — avoids import cycles between router and CSV logger.
class SpeedDebugLogSessionHolder {
  SpeedDebugLogSessionHolder._();

  static SpeedDebugLogSession _active = SpeedDebugLogSession.none;

  static SpeedDebugLogSession activeSession() => _active;

  static bool isSessionActive() => _active != SpeedDebugLogSession.none;

  static void setActive(SpeedDebugLogSession s) {
    _active = s;
  }
}
