import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime and build-time configuration.
///
/// **Precedence:** non-empty `--dart-define=KEY=value` (CI/production) overrides
/// [dotenv] values loaded by [loadAppEnv] from `assets/env/.env` + `assets/env/env.example`.
///
/// No secrets are committed in source; copy `assets/env/env.example` to `assets/env/.env` locally.
class AppConfig {
  AppConfig._();

  static String _env(String key, String dartDefineName) {
    final fromDefine = String.fromEnvironment(dartDefineName);
    if (fromDefine.isNotEmpty) return fromDefine;
    if (!dotenv.isInitialized) return '';
    return dotenv.env[key]?.trim() ?? '';
  }

  /// Project URL (Dashboard → Project Settings → API).
  static String get supabaseUrl => _env('SUPABASE_URL', 'SUPABASE_URL');

  static String get supabaseAnonKey => _env('SUPABASE_ANON_KEY', 'SUPABASE_ANON_KEY');

  static String get revenueCatPublicApiKey =>
      _env('REVENUECAT_PUBLIC_API_KEY', 'REVENUECAT_PUBLIC_API_KEY');

  /// HERE Routing / Discover REST key.
  static String get hereApiKey => _env('HERE_API_KEY', 'HERE_API_KEY');

  /// Google Maps SDK / Directions (same key type as Android `google.maps.api.key`).
  static String get googleMapsApiKey =>
      _env('GOOGLE_MAPS_API_KEY', 'GOOGLE_MAPS_API_KEY');

  /// **Web application** OAuth 2.0 client ID (Google Cloud → APIs & Services → Credentials).
  ///
  /// Used as [GoogleSignIn.serverClientId] and must match Supabase Auth → Google → Client ID.
  /// Do **not** use the Android/iOS OAuth client ID here — those belong only in Google Cloud
  /// (package name + SHA-1 for Android). The JSON download for Android often shows `"installed"`
  /// with a different client id; that is not this value.
  static String get googleWebClientId =>
      _env('GOOGLE_WEB_CLIENT_ID', 'GOOGLE_WEB_CLIENT_ID');

  /// Mapbox access token (Directions compare only — public `pk.` token).
  static String get mapboxAccessToken =>
      _env('MAPBOX_ACCESS_TOKEN', 'MAPBOX_ACCESS_TOKEN');

  /// TomTom API key for compare-provider requests.
  static String get tomtomApiKey => _env('TOMTOM_API_KEY', 'TOMTOM_API_KEY');

  static bool get useRemoteHere => supabaseUrl.trim().isNotEmpty;
}
