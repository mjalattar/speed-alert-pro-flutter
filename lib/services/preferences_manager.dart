import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../core/constants.dart';

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
  static const _kUseRemoteSpeedApi = 'use_remote_speed_api';
  static const _kUseLocalStabilizer = 'use_local_speed_stabilizer';
  static const _kLogSpeedFetches = 'log_speed_fetches';
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

  /// Keys allowed when [SharedPreferences.setPrefix] is `''` on Android (no `flutter.` prefix).
  static const Set<String> androidNativePrefsAllowList = {
    'alert_threshold_mph',
    'audible_alert_enabled',
    'alert_run_mode',
    'api_here_enabled',
    'api_tomtom_enabled',
    'api_mapbox_enabled',
    'sim_dest_preset',
    'sim_custom_dest_query',
    'sim_custom_dest_latlng',
    'sim_routing_origin_latlng',
    'sim_routing_dest_latlng',
    'overlay_hud_minimized',
    'use_remote_speed_api',
    'use_local_speed_stabilizer',
    'log_speed_fetches',
    'ui_theme_mode',
    'suppress_alerts_under_15_mph',
    'flutter_driving_tracking_active',
  };

  /// Call **before** [SharedPreferences.getInstance] on Android so native XML keys resolve without a prefix.
  static void registerAndroidSharedPrefsAllowListBeforeOpen() {
    if (kIsWeb) return;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        SharedPreferences.setPrefix(
          '',
          allowList: androidNativePrefsAllowList,
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

  /// `false` if key never written; Edge is used only when true and the build has Supabase configured.
  bool get useRemoteSpeedApi {
    if (!AppConfig.useRemoteHere) return false;
    if (!_prefs.containsKey(_kUseRemoteSpeedApi)) {
      return false;
    }
    return _prefs.getBool(_kUseRemoteSpeedApi) ?? false;
  }

  set useRemoteSpeedApi(bool v) => _prefs.setBool(_kUseRemoteSpeedApi, v);

  bool get useLocalSpeedStabilizer =>
      _prefs.getBool(_kUseLocalStabilizer) ?? false;
  set useLocalSpeedStabilizer(bool v) =>
      _prefs.setBool(_kUseLocalStabilizer, v);

  bool get logSpeedFetchesToFile => _prefs.getBool(_kLogSpeedFetches) ?? true;
  set logSpeedFetchesToFile(bool v) => _prefs.setBool(_kLogSpeedFetches, v);

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
      (_prefs.getInt(_kSimDestPreset) ?? 0).clamp(0, 6);

  set simulationDestinationPreset(int v) =>
      _prefs.setInt(_kSimDestPreset, v.clamp(0, 6));

  String get simulationCustomDestinationQuery =>
      _prefs.getString(_kSimCustomDestQuery) ?? '';

  set simulationCustomDestinationQuery(String v) =>
      _prefs.setString(_kSimCustomDestQuery, v);

  String get simulationCustomDestinationLatLng =>
      _prefs.getString(_kSimCustomDestLatlng) ?? '';

  set simulationCustomDestinationLatLng(String v) =>
      _prefs.setString(_kSimCustomDestLatlng, v);

  String get simulationRoutingOriginLatLng =>
      _prefs.getString(_kSimRoutingOriginLatlng) ?? '';

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
