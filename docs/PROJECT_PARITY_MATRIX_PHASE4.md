# Project Parity Matrix — Phase 4 (post-fix)

Updates after overlay bridge, nanosecond fix-age, provider bridge, debounce `>`, `checkSpeedAlert` else-branch, prefs `commit`, and mechanical LocationProcessor constant proof.

| Kotlin source | Flutter target | Phase 4 category |
|---------------|------------------|------------------|
| `OverlayPermission.kt` | `OverlayPermissionBridge.kt` + `overlay_permission_platform.dart` + Settings “Background overlay” | **MATCHED 1:1** (logic duplicated; invoked via MethodChannel) |
| `SpeedAlertService.checkSpeedAlert` | `DrivingSessionNotifier._checkSpeedAlertLikeKotlin` | **MATCHED 1:1** (same predicates; `else if (hasLimit)` OK log via `developer.log`; overlay after audible branch) |
| `SpeedAlertService` tone debounce `> 3000` | `SpeedAlertSoundBridge` | **MATCHED 1:1** (block when `<= minIntervalMs`) |
| `SpeedLimitLoggingContext` fix age | `SpeedLimitLoggingContext.snapshotAsync` + `AndroidSystemClock.elapsedRealtimeNanos` | **MATCHED 1:1** (ns delta / 1e6; async snapshot for channel read) |
| `Location.getProvider()` | `DrivingLocationHub` → `FusedDrivingLocation` → `updateFromPosition` | **MATCHED 1:1** (fused path); Geolocator-only Android: provider empty (no `Location` object) |
| `PreferencesManager.flushSimulationFormInputsToDisk` / `commit` | `speed_alert_pro/speed_alert_prefs` `commitStringMap` + `_prefs.reload()` | **MATCHED 1:1** (single native `commit`) |
| `LocationProcessor` thresholds | `location_processor.dart` `static const` + file header `MECHANICAL_PARITY` list | **MATCHED 1:1** (numeric identity documented) |
| `HereApiService` / Gson models | `here_api_service.dart` / `HereSpan.fromJson` | **MATCHED 1:1** (JSON keys below) |
| `TomTomApiService` + aggregator parse | `compare_providers_service.dart` + `AnnotationSectionSpeedModel.fromTomTomSnapRouteJson` | **MATCHED 1:1** (keys below) |
| `MapboxApiService` + parse | `compare_providers_service.dart` + `fromMapboxDirectionsJson` | **MATCHED 1:1** (keys below) |

---

## Task 4 — JSON key strings (HERE / TomTom / Mapbox)

### HERE Routing v8 (response)

| JSON key | Kotlin (`HereApiService` / `Span`) | Dart (`here_api_service.dart` / `HereSpan.fromJson`) |
|----------|-------------------------------------|------------------------------------------------------|
| Top-level routes array | `routes` | `routes` |
| Per-route sections | `sections` | `sections` |
| Section polyline | `polyline` | `polyline` |
| Section spans | `spans` | `spans` |
| Span offset | `offset` | `offset` |
| Span length | `length` | `length` |
| Span speed (m/s) | `speedLimit` | `speedLimit` |
| Span topology id | `segmentRef` | `segmentRef` |
| Span functional class | `functionalClass` | `functionalClass` |
| Discover items | `items` | `items` |
| Discover position | `position` | `position` |
| Discover access[] | `access` | `access` |
| Lat / lng | `lat`, `lng` | `lat`, `lng` |

HERE uses **camelCase** in JSON; Gson maps to Kotlin `speedLimit` etc. Dart uses the **same** string keys.

### TomTom Snap (response)

| JSON key | Dart usage (`annotation_section_speed_model.dart`) |
|----------|-----------------------------------------------------|
| `detailedError` | error sentinel |
| `route` | object or `features` list |
| `features` | route feature array |
| `type` | FeatureCollection / Feature |
| `geometry` | object |
| `coordinates` | LineString / Polygon rings |
| `properties` | object |
| `speedLimits` | speed limit array |
| `value`, `unit`, `type` | limit entries |
| `speedProfile` | optional |
| `projectedPoints` | array |
| `snapResult` | string |
| `routeIndex` | int |

Matches Kotlin `AnnotationSectionSpeedModel` / aggregator TomTom path (same TomTom field names).

### Mapbox Directions (response)

| JSON key | Dart usage |
|----------|------------|
| `routes` | array |
| `geometry` | leg geometry |
| `coordinates` | `[lon, lat][]` |
| `legs` | array |
| `annotation` | object |
| `maxspeed` | array (per-edge or segment annotation) |

Matches Mapbox Directions JSON (camelCase `maxspeed` annotation).

**Critical failure check:** No `speed_limit` vs `speedLimit` mismatch on HERE spans — both use **`speedLimit`**.

**Separate API (not HERE Routing v8 JSON):** Kotlin `HereEdgeFunctionClient` uses Gson `@SerializedName("speed_limit_mph")` for the edge-function payload. That is unrelated to router `Span.speedLimit` (m/s). Flutter must use the same key if/when that edge path is ported.

---

## Task 2 — `checkSpeedAlert` if/else sequence (mechanical)

| Step | Kotlin `SpeedAlertService.checkSpeedAlert` | Dart `_checkSpeedAlertLikeKotlin` |
|------|---------------------------------------------|-------------------------------------|
| Threshold / mode / foreground | L380–383 | `threshold`, `mode`, `inForeground` |
| `hasLimit` | `lim != null && lim > 0` (L386) | Same |
| `suppressLowSpeedAlerts` | `suppressAlertsWhenUnder15Mph && speedMph < LOW_SPEED...` (L387–388) | Same constant `kLowSpeedAlertSuppressBelowMph` |
| `isSpeeding` | `!suppress && lim != null && lim > 0 && speedMph > lim + threshold` (L389–390) | Same (`>` on speed vs limit+threshold) |
| `shouldPlayAudible` | `isAudibleAlertEnabled && isSpeeding && when(mode) { NORMAL→fg; BG_SOUND/OVERLAY→true; else→false }` (L398–402) | `switch (mode)` with same three modes |
| Diagnostic log | L392–396 | `developer.log` same fields |
| Branch 1 | `if (shouldPlayAudible)` → ALERT log (L405), debounced tone (L406–412) | ALERT `developer.log` + `playDebouncedIfEligible` (native `> minIntervalMs` parity) |
| Branch 2 | `else if (hasLimit)` → OK log (L414–415) | Same |
| Overlay | L418–427 after branches | `OverlayPlatformChannel.sync` with same `showOverlay` inputs (Dart mirrors predicates) |

Tone “Playing tone alert” is logged in `SpeedAlertSoundBridge` when playback is not debounced, matching Kotlin L408.

---

## Files still structurally split (not wrong, but not single-file 1:1)

- `SpeedLimitAggregator.kt` → `speed_limit_aggregator.dart` + `compare_providers_service.dart`
- `MainActivity.kt` (Compose monolith) → multiple `lib/screens/*` + embedding `MainActivity.kt`
