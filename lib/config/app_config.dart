/// Build-time configuration (`String.fromEnvironment` / `--dart-define`).
///
/// Defaults match the Speed Alert Pro Android project. Override any value with
/// `--dart-define=KEY=value` for CI/production without editing source.
class AppConfig {
  AppConfig._();

  /// Project URL (Dashboard → Project Settings → API).
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://kwcupbvwsmubsixciorg.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_VPhal2dHGSrc94Dg69g2kA_rjuAwNmK',
  );

  static const String revenueCatPublicApiKey = String.fromEnvironment(
    'REVENUECAT_PUBLIC_API_KEY',
    defaultValue: 'test_vwAfOZPwLoAuWxenWkDCmBZAGUU',
  );

  /// HERE Routing / Discover REST key.
  static const String hereApiKey = String.fromEnvironment(
    'HERE_API_KEY',
    defaultValue: 'vSXMWQK3pVRDDNLuvzcSUdzH5QJ7KMjCdeqvzQGNU-8',
  );

  /// Google Maps SDK / Directions (same key type as Android `google.maps.api.key`).
  static const String googleMapsApiKey = String.fromEnvironment(
    'GOOGLE_MAPS_API_KEY',
    defaultValue: 'AIzaSyBpMib5jhVaz9qB_YGMOWTNqcd-5uKz1Dw',
  );

  /// **Web application** OAuth 2.0 client ID (Google Cloud → APIs & Services → Credentials).
  ///
  /// Used as [GoogleSignIn.serverClientId] and must match Supabase Auth → Google → Client ID.
  /// Do **not** use the Android/iOS OAuth client ID here — those belong only in Google Cloud
  /// (package name + SHA-1 for Android). The JSON download for Android often shows `"installed"`
  /// with a different client id; that is not this value.
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue:
        '92848872267-mqvfo6n406eq3rck37oc37d3kt5uicp8.apps.googleusercontent.com',
  );

  /// Mapbox access token (Directions compare only — public `pk.` token).
  ///
  /// No default in repo (GitHub push protection). Set via `--dart-define=MAPBOX_ACCESS_TOKEN=pk....`
  /// or Android `gradle.properties` / CI secrets.
  static const String mapboxAccessToken = String.fromEnvironment(
    'MAPBOX_ACCESS_TOKEN',
    defaultValue: '',
  );

  /// TomTom API key for compare-provider requests.
  static const String tomtomApiKey = String.fromEnvironment(
    'TOMTOM_API_KEY',
    defaultValue: 'T6DkF5gnYZKYB5q6voI8Q9modZzVOKnW',
  );

  static bool get useRemoteHere => supabaseUrl.trim().isNotEmpty;
}
