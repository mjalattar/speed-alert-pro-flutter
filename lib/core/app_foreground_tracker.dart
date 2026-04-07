/// True while the main shell is in the **resumed** app lifecycle (user can see in-app speed UI).
///
/// Used to gate background-only alerts, overlay, and [AlertRunMode.normal] HERE pause.
///
/// **Default:** [isMainActivityVisible] is `false` at class initialization until the first resume.
///
/// Dart isolates are single-threaded for Dart code; this flag is the single source for **logic** reads
/// outside [WidgetRef] (e.g. platform callbacks). Sync with [DrivingSessionNotifier.syncAppLifecycle] and
/// [appForegroundVisibleProvider] so logic and UI agree.
class AppForegroundTracker {
  AppForegroundTracker._();

  /// Whether the in-app shell is considered visible for alert/overlay gating.
  static bool isMainActivityVisible = false;
}
