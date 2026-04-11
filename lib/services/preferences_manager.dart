import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../core/constants.dart'
    show AlertRunMode, AppThemeMode, SpeedLimitPrimaryProvider;

/// App preferences: same **keys**, **defaults**, and (on Android) **XML file** `SpeedAlertPrefs` via
/// [MainActivity] Pigeon override + [registerAndroidSharedPrefsAllowListBeforeOpen].
class PreferencesManager {
  PreferencesManager(this._prefs);

  final SharedPreferences _prefs;

  /// Single atomic `commit`-style write on Android [SpeedAlertPrefs].
  static const MethodChannel _nativePrefsCommit =
      MethodChannel('speed_alert_pro/speed_alert_prefs');

  static const _kAlertThreshold = 'alert_threshold_mph';
  static const _kAudibleAlert = 'audible_alert_enabled';
  static const _kAlertRunMode = 'alert_run_mode';
  static const _kApiHere = 'api_here_enabled';
  static const _kApiTomTom = 'api_tomtom_enabled';
  static const _kApiMapbox = 'api_mapbox_enabled';
  static const _kApiRemote = 'api_remote_enabled';
  /// [SpeedLimitPrimaryProvider] value (here, tomTom, mapbox, remote).
  static const _kPrimarySpeedLimitProvider = 'primary_speed_limit_provider';
  static const _kUiThemeMode = 'ui_theme_mode';
  static const _kSuppressUnder15 = 'suppress_alerts_under_15_mph';
  static const _kOverlayHudMinimized = 'overlay_hud_minimized';

  /// Flutter-only: last explicit “Start driving” while Android fused FG service may still be running
  /// after Activity/engine death (DKA). Stored in shared [SpeedAlertPrefs].
  static const _kFlutterDrivingTrackingActive = 'flutter_driving_tracking_active';

  static const _kSimDestPreset = 'sim_dest_preset';
  static const _kSimCustomDestQuery = 'sim_custom_dest_query';
  static const _kSimCustomDestLatlng = 'sim_custom_dest_latlng';
  static const _kSimRoutingOriginLatlng = 'sim_routing_origin_latlng';
  static const _kSimRoutingDestLatlng = 'sim_routing_dest_latlng';

  /// Default “Source location” for the coordinates preset when unset (lat,lng).
  static const String kDefaultSimulationRoutingOriginLatLng =
      '29.526065,-95.015465';

  /// Keys allowed when [SharedPreferences.setPrefix] is `''` on Android (no `flutter.` prefix).
  static const Set<String> androidNativePrefsAllowList = {
    'alert_threshold_mph',
    'audible_alert_enabled',
    'alert_run_mode',
    'api_here_enabled',
    'api_tomtom_enabled',
    'api_mapbox_enabled',
    'api_remote_enabled',
    'primary_speed_limit_provider',
    'sim_dest_preset',
    'sim_custom_dest_query',
    'sim_custom_dest_latlng',
    'sim_routing_origin_latlng',
    'sim_routing_dest_latlng',
    'overlay_hud_minimized',
    'ui_theme_mode',
    'suppress_alerts_under_15_mph',
    'flutter_driving_tracking_active',
    // Session persistence keys — required for Supabase auth and custom recovery.
    'speed_alert_pro_session_json',
  };

  /// Build the full allow list including the Supabase auth key derived from the project URL.
  static Set<String> buildFullAllowList() {
    final list = Set<String>.from(androidNativePrefsAllowList);
    final supabaseUrl = AppConfig.supabaseUrl.trim();
    if (supabaseUrl.isNotEmpty) {
      try {
        final host = Uri.parse(supabaseUrl).host.split('.').first;
        list.add('sb-$host-auth-token');
      } catch (_) {}
    }
    return list;
  }

  /// Call **before** [SharedPreferences.getInstance] on Android so native XML keys resolve without a prefix.
  static void registerAndroidSharedPrefsAllowListBeforeOpen() {
    if (kIsWeb) return;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        SharedPreferences.setPrefix(
          '',
          allowList: buildFullAllowList(),
        );
      }
    } catch (_) {
      // Tests / unsupported embedders: fall back to default prefix.
    }
  }

  static Future<PreferencesManager> open() async {
    final p = await SharedPreferences.getInstance();
    return PreferencesManager(p);
  }

  int get alertThresholdMph => _prefs.getInt(_kAlertThreshold) ?? 5;
  set alertThresholdMph(int v) => _prefs.setInt(_kAlertThreshold, v);

  bool get isAudibleAlertEnabled => _prefs.getBool(_kAudibleAlert) ?? false;
  set isAudibleAlertEnabled(bool v) => _prefs.setBool(_kAudibleAlert, v);

  int get alertRunMode {
    final v = _prefs.getInt(_kAlertRunMode);
    if (v == null) {
      return AlertRunMode.normal;
    }
    return v.clamp(0, 2);
  }

  set alertRunMode(int v) => _prefs.setInt(_kAlertRunMode, v.clamp(0, 2));

  bool get isHereApiEnabled => _prefs.getBool(_kApiHere) ?? true;
  set isHereApiEnabled(bool v) => _prefs.setBool(_kApiHere, v);

  bool get isTomTomApiEnabled => _prefs.getBool(_kApiTomTom) ?? false;
  set isTomTomApiEnabled(bool v) => _prefs.setBool(_kApiTomTom, v);

  bool get isMapboxApiEnabled => _prefs.getBool(_kApiMapbox) ?? false;
  set isMapboxApiEnabled(bool v) => _prefs.setBool(_kApiMapbox, v);

  /// Enables the remote (Edge) pipeline when [AppConfig.useRemoteHere] is true.
  bool get isRemoteApiEnabled =>
      AppConfig.useRemoteHere && (_prefs.getBool(_kApiRemote) ?? true);
  set isRemoteApiEnabled(bool v) => _prefs.setBool(_kApiRemote, v);

  /// Which API drives the **main** speed limit (display + alerts). Default HERE.
  int get primarySpeedLimitProvider =>
      (_prefs.getInt(_kPrimarySpeedLimitProvider) ?? SpeedLimitPrimaryProvider.here)
          .clamp(SpeedLimitPrimaryProvider.here, SpeedLimitPrimaryProvider.remote);

  set primarySpeedLimitProvider(int v) =>
      _prefs.setInt(_kPrimarySpeedLimitProvider, v.clamp(SpeedLimitPrimaryProvider.here, SpeedLimitPrimaryProvider.remote));

  /// Effective primary when the stored choice is disabled — first enabled in order HERE → remote → TomTom → Mapbox, else HERE.
  int get resolvedPrimarySpeedLimitProvider {
    final want = primarySpeedLimitProvider;
    if (want == SpeedLimitPrimaryProvider.here && isHereApiEnabled) {
      return SpeedLimitPrimaryProvider.here;
    }
    if (want == SpeedLimitPrimaryProvider.remote &&
        AppConfig.useRemoteHere &&
        isRemoteApiEnabled) {
      return SpeedLimitPrimaryProvider.remote;
    }
    if (want == SpeedLimitPrimaryProvider.tomTom && isTomTomApiEnabled) {
      return SpeedLimitPrimaryProvider.tomTom;
    }
    if (want == SpeedLimitPrimaryProvider.mapbox && isMapboxApiEnabled) {
      return SpeedLimitPrimaryProvider.mapbox;
    }
    if (isHereApiEnabled) return SpeedLimitPrimaryProvider.here;
    if (AppConfig.useRemoteHere && isRemoteApiEnabled) {
      return SpeedLimitPrimaryProvider.remote;
    }
    if (isTomTomApiEnabled) return SpeedLimitPrimaryProvider.tomTom;
    if (isMapboxApiEnabled) return SpeedLimitPrimaryProvider.mapbox;
    return SpeedLimitPrimaryProvider.here;
  }

  /// Short label for UI (speed card, session [SpeedLimitData].provider, etc.).
  /// Uses the **selected** main provider so the label updates as soon as the user changes the setting
  /// ([resolvedPrimarySpeedLimitProvider] still drives which API actually powers alerts).
  String get primarySpeedLimitProviderDisplayName {
    switch (primarySpeedLimitProvider) {
      case SpeedLimitPrimaryProvider.here:
        return 'HERE Maps';
      case SpeedLimitPrimaryProvider.remote:
        return 'Remote';
      case SpeedLimitPrimaryProvider.tomTom:
        return 'TomTom';
      case SpeedLimitPrimaryProvider.mapbox:
        return 'Mapbox';
      default:
        return 'HERE Maps';
    }
  }

  /// Label for the **effective** main provider (after API enable checks). Use for the main speed limit
  /// headline so it matches [resolvedPrimarySpeedLimitProvider] and the primary/secondary rows below.
  String get resolvedPrimarySpeedLimitProviderDisplayName {
    switch (resolvedPrimarySpeedLimitProvider) {
      case SpeedLimitPrimaryProvider.here:
        return 'HERE Maps';
      case SpeedLimitPrimaryProvider.remote:
        return 'Remote';
      case SpeedLimitPrimaryProvider.tomTom:
        return 'TomTom';
      case SpeedLimitPrimaryProvider.mapbox:
        return 'Mapbox';
      default:
        return 'HERE Maps';
    }
  }

  /// Speed-limit CSV / HTTP logging is always enabled (no user toggle).
  bool get logSpeedFetchesToFile => true;

  int get uiThemeMode =>
      (_prefs.getInt(_kUiThemeMode) ?? AppThemeMode.auto).clamp(0, 2);
  set uiThemeMode(int v) => _prefs.setInt(_kUiThemeMode, v.clamp(0, 2));

  bool get suppressAlertsWhenUnder15Mph =>
      _prefs.getBool(_kSuppressUnder15) ?? false;
  set suppressAlertsWhenUnder15Mph(bool v) =>
      _prefs.setBool(_kSuppressUnder15, v);

  bool get isOverlayHudMinimized =>
      _prefs.getBool(_kOverlayHudMinimized) ?? false;
  set isOverlayHudMinimized(bool v) =>
      _prefs.setBool(_kOverlayHudMinimized, v);

  /// See [_kFlutterDrivingTrackingActive].
  bool get flutterDrivingTrackingActive =>
      _prefs.getBool(_kFlutterDrivingTrackingActive) ?? false;
  set flutterDrivingTrackingActive(bool v) =>
      _prefs.setBool(_kFlutterDrivingTrackingActive, v);

  int get simulationDestinationPreset =>
      _prefs.getInt(_kSimDestPreset) ?? 0;

  set simulationDestinationPreset(int v) =>
      _prefs.setInt(_kSimDestPreset, v.clamp(0, 3));

  String get simulationCustomDestinationQuery =>
      _prefs.getString(_kSimCustomDestQuery) ?? '';

  set simulationCustomDestinationQuery(String v) =>
      _prefs.setString(_kSimCustomDestQuery, v);

  String get simulationCustomDestinationLatLng =>
      _prefs.getString(_kSimCustomDestLatlng) ?? '';

  set simulationCustomDestinationLatLng(String v) =>
      _prefs.setString(_kSimCustomDestLatlng, v);

  String get simulationRoutingOriginLatLng {
    final s = _prefs.getString(_kSimRoutingOriginLatlng) ?? '';
    if (s.trim().isEmpty) return kDefaultSimulationRoutingOriginLatLng;
    return s;
  }

  set simulationRoutingOriginLatLng(String v) =>
      _prefs.setString(_kSimRoutingOriginLatlng, v);

  String get simulationRoutingDestinationLatLng =>
      _prefs.getString(_kSimRoutingDestLatlng) ?? '';

  set simulationRoutingDestinationLatLng(String v) =>
      _prefs.setString(_kSimRoutingDestLatlng, v);

  /// `commit`-style batch write so simulation fields survive preset switches and process death
  /// before async `apply` would finish.
  Future<void> flushSimulationFormInputsToDisk({
    required String routingOriginLatLng,
    required String routingDestinationLatLng,
    required String customDestinationQuery,
    String? customDestinationLatLng,
  }) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final m = <String, String>{
        _kSimRoutingOriginLatlng: routingOriginLatLng,
        _kSimRoutingDestLatlng: routingDestinationLatLng,
        _kSimCustomDestQuery: customDestinationQuery,
      };
      if (customDestinationLatLng != null) {
        m[_kSimCustomDestLatlng] = customDestinationLatLng;
      }
      try {
        await _nativePrefsCommit.invokeMethod<void>('commitStringMap', m);
      } catch (_) {
        await _prefs.setString(_kSimRoutingOriginLatlng, routingOriginLatLng);
        await _prefs.setString(_kSimRoutingDestLatlng, routingDestinationLatLng);
        await _prefs.setString(_kSimCustomDestQuery, customDestinationQuery);
        if (customDestinationLatLng != null) {
          await _prefs.setString(_kSimCustomDestLatlng, customDestinationLatLng);
        }
      }
      try {
        await _prefs.reload();
      } catch (_) {
        // Older shared_preferences without reload: in-memory may lag until next read.
      }
      return;
    }
    await _prefs.setString(_kSimRoutingOriginLatlng, routingOriginLatLng);
    await _prefs.setString(_kSimRoutingDestLatlng, routingDestinationLatLng);
    await _prefs.setString(_kSimCustomDestQuery, customDestinationQuery);
    if (customDestinationLatLng != null) {
      await _prefs.setString(_kSimCustomDestLatlng, customDestinationLatLng);
    }
  }
}
