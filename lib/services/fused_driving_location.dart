import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

/// Android: Google Play **Fused Location** via foreground service (native bridge).
class FusedDrivingLocation {
  FusedDrivingLocation._();

  static const MethodChannel _method = MethodChannel('speed_alert_pro/driving_location');
  static const EventChannel _events = EventChannel('speed_alert_pro/fused_location_stream');

  /// Subscribe **before** [start] so the native [EventChannel.StreamHandler.onListen] sets the sink.
  static Stream<Position> positionStream() {
    return _events.receiveBroadcastStream().map(_toPosition);
  }

  /// Whether the native fused foreground service is still running (can outlive the activity).
  static Future<bool> isForegroundServiceRunning() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final v = await _method.invokeMethod<bool>('isRunning');
      return v == true;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _method.invokeMethod<void>('start');
    } on MissingPluginException {
      return;
    }
  }

  static Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _method.invokeMethod<void>('stop');
    } on MissingPluginException {
      return;
    }
  }

  /// Pause or resume fused updates when normal mode backgrounds/foregrounds the app.
  static Future<void> setPaused(bool paused) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _method.invokeMethod<void>('setPaused', paused);
    } on MissingPluginException {
      return;
    }
  }

  /// When true, native side drops fused callbacks while road-test simulation runs.
  static Future<void> setSimulationActive(bool active) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _method.invokeMethod<void>('setSimulationActive', active);
    } on MissingPluginException {
      return;
    }
  }

  /// Stashed per-fix Android extras (elapsed realtime ns, provider) for the Dart pipeline.
  static int? _pendingElapsedRealtimeNs;
  static String _pendingProvider = '';

  static int? takePendingElapsedRealtimeNs() {
    final v = _pendingElapsedRealtimeNs;
    _pendingElapsedRealtimeNs = null;
    return v;
  }

  static String takePendingProvider() {
    final p = _pendingProvider;
    _pendingProvider = '';
    return p;
  }

  static Position _toPosition(dynamic event) {
    final m = Map<Object?, Object?>.from(event as Map);
    double d(String k) => (m[k] as num).toDouble();
    int i(String k) => (m[k] as num).toInt();
    final ts = i('timestampMs');
    final ern = m['elapsedRealtimeNanos'];
    _pendingElapsedRealtimeNs =
        ern is int ? ern : (ern is num ? ern.toInt() : null);
    final prov = m['provider'];
    _pendingProvider = prov is String ? prov : (prov?.toString() ?? '');
    return Position(
      latitude: d('latitude'),
      longitude: d('longitude'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      accuracy: d('accuracy'),
      altitude: d('altitude'),
      altitudeAccuracy: d('altitudeAccuracy'),
      heading: d('heading'),
      headingAccuracy: d('headingAccuracy'),
      speed: d('speed'),
      speedAccuracy: d('speedAccuracy'),
      isMocked: m['isMocked'] == true,
    );
  }
}
