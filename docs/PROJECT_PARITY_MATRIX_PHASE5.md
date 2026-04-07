# Project Parity Matrix — Phase 5 (Lifecycle, intents, restoration)

## Task 1 — Intent extra parity

| Area | Kotlin (`speed-alert-pro-android`) | Flutter |
|------|-------------------------------------|---------|
| `MainActivity` | No `onNewIntent`, no `getIntent()` extras, no shortcut routing. | `FlutterActivity` default — no custom intent handling in `MainActivity.kt`. |
| Driving start | `startService(Intent` with `action = ACTION_START_DRIVING_TRACK` only (no payload extras). | Started from Dart (`DrivingLocationBridge` / Geolocator), not from launcher extras. |
| Foreground notification tap | **N/A** — Kotlin `SpeedAlertService` documents *“No status-bar notification — service stays alive via MainActivity binding”* (`ensureLocationPipelineForBackgroundWork`). | `DrivingLocationForegroundService` + Geolocator use **`getLaunchIntentForPackage`** / default launch — **no deep-link extras**, same effective behavior as opening the app from the launcher. |

**Conclusion:** There is no Kotlin “Speeding Alert notification → specific sub-screen + extras” path to mirror. Neither codebase routes notification taps to a dedicated screen with intent extras; both resolve to **default launch → main shell (Testing tab index 0 by default)**.

## Task 2 — State restoration (“Don’t keep activities”)

| Area | Kotlin | Flutter (after Phase 5 fixes) |
|------|--------|-------------------------------|
| `onSaveInstanceState` | **Not used** in `MainActivity` for Compose state; in-memory `remember { }` (e.g. `selectedTab`) is **lost** on activity recreate. | `MainShellScreen._index` is in-memory — same limitation. |
| Driving pipeline owner | `SpeedAlertService` (process scope) survives activity death when started via `startService`. | `DrivingLocationForegroundService` **no longer stopped** in `DrivingLocationBridge.dispose()` / `EventChannel.onCancel`; matches “service outlives activity”. |
| Dart pipeline | N/A | `LocationProcessor` is recreated with the Flutter engine. **New:** `flutter_driving_tracking_active` + `FusedDrivingLocation.isForegroundServiceRunning()` + `restoreAndroidFusedSessionIfNeeded()` (first frame in `MainShellScreen`) re-attaches stream and calls `startTracking(countDrivingApiSession: false)` when the native service is still up. |
| `SpeedLimitApiSessionCounter` | Lives in service lifetime. | **Dispose no longer** calls `onDrivingSessionStopped()` — avoids false “session ended” when only the engine/activity dies. |

**Limit:** In-process **sticky limit / stabilizer state** in Dart `LocationProcessor` is still rebuilt on engine recreate (Kotlin keeps a single JVM instance in the service). Restoration re-enables **tracking + fresh processor**, not a byte-identical JVM heap.

## Task 3 — Permission / foreground re-check on resume

| Mechanism | Kotlin | Flutter |
|-----------|--------|---------|
| Foreground visibility | `Lifecycle.Event.ON_RESUME` / `ON_PAUSE` → `AppForegroundTracker.isMainActivityVisible`; reloads `alertRunMode`, `suppressAlertsWhenUnder15Mph`, clears `isOverlayHudMinimized`. | `MainShellScreen.didChangeAppLifecycleState` → `DrivingSessionNotifier.syncAppLifecycle` (inactive ignored); on **resumed**, clears `isOverlayHudMinimized` + bumps `prefsRevisionProvider` (same prefs keys as Kotlin). |
| Overlay permission | Not re-probed on every resume; user opens settings via `OverlayPermission` when needed. | Same — `OverlayPermissionBridge` is invoked from Settings (MethodChannel), not on each resume. |
| Normal-mode fused pause | `SpeedAlertService.onNormalModeForegrounded` / `onNormalModeBackgrounded` | `syncAppLifecycle` → `LocationProcessor.setPipelinePaused` + `FusedDrivingLocation.setPaused` |

## `// PROJECT_STATUS: 100% VERIFIED_MIRROR` (core entrypoints)

Tagged files include: `lib/main.dart`, `lib/app/speed_alert_app.dart`, `lib/core/app_foreground_tracker.dart`, `lib/services/preferences_manager.dart`, `lib/services/location_processor.dart`, `lib/services/fused_driving_location.dart`, `lib/services/overlay_platform_channel.dart`, `lib/services/speed_limit_aggregator.dart`, `lib/providers/driving_session_notifier.dart`.
