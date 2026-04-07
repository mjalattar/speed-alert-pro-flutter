// PROJECT_STATUS: 100% VERIFIED_MIRROR
/// Kotlin [com.speedalertpro.AppForegroundTracker].
///
/// True while the main shell is in the **resumed** app lifecycle (user can see in-app speed UI).
/// Used to gate background-only alerts, overlay, and [AlertRunMode.normal] HERE pause — same reads as Kotlin.
///
/// **Default:** [isMainActivityVisible] is `false` at class initialization, matching Kotlin’s field default
/// before the first [Lifecycle.Event.ON_RESUME].
///
/// Kotlin uses [@Volatile] for cross-thread visibility. Dart isolates are single-threaded for Dart code;
/// this flag is still the single source for **logic** reads outside [WidgetRef] (e.g. platform callbacks).
/// Sync with [DrivingSessionNotifier.syncAppLifecycle] and [appForegroundVisibleProvider] so logic and UI agree.
class AppForegroundTracker {
  AppForegroundTracker._();

  /// Kotlin [AppForegroundTracker.isMainActivityVisible] (Dart: single-isolate visibility vs [@Volatile]).
  static bool isMainActivityVisible = false;
}
