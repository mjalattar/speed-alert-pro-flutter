# Speed Alert Pro (Flutter)

Speed and posted limit alerts for **iOS and Android**, built with **Flutter / Dart**.

## Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) 3.24+ (stable) with `flutter` and `dart` on your `PATH`.

## First-time setup (generate `android/` and `ios/`)

If platform folders are missing, from this directory:

```powershell
flutter create . --project-name speed_alert_pro --org com.speedalertpro
```

Flutter merges in missing files without replacing your `lib/` or `pubspec.yaml`. Then:

```powershell
flutter pub get
```

Create `android/local.properties` if needed (Flutter may do this automatically):

- `sdk.dir` — Android SDK path  
- `flutter.sdk` — Flutter SDK root  

## Run (API keys)

Keys are supplied with **`--dart-define`** (see `lib/config/app_config.dart`):

```powershell
flutter run `
  --dart-define=HERE_API_KEY=your_here_rest_key
```

Optional (remote HERE via Supabase — see **`supabase/SETUP.txt`**):

```powershell
flutter run `
  --dart-define=HERE_API_KEY=your_here_key `
  --dart-define=SUPABASE_URL=https://YOUR_REF.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=your_anon_key `
  --dart-define=REVENUECAT_PUBLIC_API_KEY=your_rc_public_key `
  --dart-define=GOOGLE_MAPS_API_KEY=your_maps_key `
  --dart-define=GOOGLE_WEB_CLIENT_ID=your_web_client_id.apps.googleusercontent.com `
  --dart-define=MAPBOX_ACCESS_TOKEN=your_mapbox_pk_token `
  --dart-define=TOMTOM_API_KEY=your_tomtom_key
```

When `SUPABASE_URL` is non-empty, `AppConfig.useRemoteHere` is true.

### Auth + subscription

1. **`AppRootGate`**: if `SUPABASE_URL` is set, the user signs in with Google before the main UI.
2. **Entitlement**: with **Use Supabase Edge for speed**, the app reads trial/subscription state (Supabase + RevenueCat) and may show **`SubscriptionPaywallScreen`**.
3. **RevenueCat**: after Google sign-in, `Purchases.logIn(supabaseUserId)` runs when configured.

Use the **Web OAuth client ID** for `GOOGLE_WEB_CLIENT_ID`. For **iOS**, add the URL scheme from Google’s iOS client to `Info.plist` after `flutter create` — see [google_sign_in](https://pub.dev/packages/google_sign_in).

## Features (overview)

- HERE Routing v8 for alert limits (local REST or Edge), TomTom / Mapbox compare pipelines, road-test simulation, Android foreground fused location, overlay HUD (where implemented on platform).

## Tests

```powershell
flutter test
```

## Project layout

- `supabase/` — SQL migration, Edge Function `here-speed`, `config.toml`, **SETUP.txt**
- `lib/config/` — `AppConfig` (`String.fromEnvironment`)
- `lib/services/` — HERE, Edge client, `LocationProcessor`, preferences, aggregators, platform bridges
- `lib/providers/` — Riverpod state
- `lib/widgets/` / `lib/screens/` — UI
