// PROJECT_STATUS: 100% VERIFIED_MIRROR
// Phase 5: Fused FG service + prefs [flutterDrivingTrackingActive] mirror Kotlin service surviving Activity death.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../core/android_system_clock.dart';
import '../core/constants.dart';
import '../engine/geo_coordinate.dart';
import '../engine/here_section_speed_model.dart';
import '../models/speed_limit_data.dart';
import '../services/compare_providers_service.dart';
import '../services/fused_driving_location.dart';
import '../services/location_processor.dart';
import '../services/mock_location_tester.dart';
import '../services/speed_alert_sound_platform.dart';
import '../services/overlay_platform_channel.dart';
import '../services/simulation_route_service.dart';
import '../logging/speed_debug_log_router.dart';
import '../logging/speed_limit_api_session_counter.dart';
import '../core/app_foreground_tracker.dart';
import 'app_providers.dart';

/// Kotlin [SpeedAlertService] — single owner of driving location stream, [LocationProcessor],
/// overlay hooks, and alert audio policy. Widgets only observe [drivingSessionProvider]; they must not
/// reorder “location → pipeline → UI” relative to this notifier.
///
/// Latest simulated fix for the Testing map (Kotlin [currentLocation] → marker + camera).
final simulationMapAnchorProvider =
    StateProvider<({double lat, double lng})?>((ref) => null);

class DrivingSessionState {
  const DrivingSessionState({
    this.speedMph = 0,
    this.limitMph,
    this.isTracking = false,
    this.isSimulating = false,
    this.permissionDenied = false,
    this.lastError,
    this.hereData,
    this.lastFetchUtc,
    this.tomTomCompareMph,
    this.mapboxCompareMph,
    this.simulatedSpeedMph = 30,
    this.drivingSessionPipelineUpdates = 0,
    this.simulationRoutePolyline = const [],
    this.lastFixLat,
    this.lastFixLng,
  });

  final double speedMph;
  final double? limitMph;
  final bool isTracking;
  final bool isSimulating;
  final bool permissionDenied;
  final String? lastError;
  final SpeedLimitData? hereData;
  final DateTime? lastFetchUtc;
  final int? tomTomCompareMph;
  final int? mapboxCompareMph;

  /// Synthetic route sim speed (Kotlin [MockLocationTester] +/- adjustment).
  final int simulatedSpeedMph;

  /// Increments on each HERE pipeline callback while driving (not simulating).
  final int drivingSessionPipelineUpdates;

  /// Decoded HERE route for map polyline (Kotlin [routePoints] / [PolylineDecoder.decode]).
  final List<GeoCoordinate> simulationRoutePolyline;

  /// Kotlin [SpeedAlertService._currentLocation] / [updateLocation] — set **before** [LocationProcessor.processNewLocation].
  final double? lastFixLat;
  final double? lastFixLng;

  bool isSpeeding(int thresholdMph, bool suppressUnder15) {
    final lim = limitMph;
    if (lim == null || lim <= 0) return false;
    if (suppressUnder15 && speedMph < kLowSpeedAlertSuppressBelowMph) {
      return false;
    }
    return speedMph > lim + thresholdMph;
  }

  DrivingSessionState copyWith({
    double? speedMph,
    double? limitMph,
    bool? isTracking,
    bool? isSimulating,
    bool? permissionDenied,
    String? lastError,
    SpeedLimitData? hereData,
    DateTime? lastFetchUtc,
    int? tomTomCompareMph,
    int? mapboxCompareMph,
    int? simulatedSpeedMph,
    int? drivingSessionPipelineUpdates,
    List<GeoCoordinate>? simulationRoutePolyline,
    double? lastFixLat,
    double? lastFixLng,
  }) {
    return DrivingSessionState(
      speedMph: speedMph ?? this.speedMph,
      limitMph: limitMph ?? this.limitMph,
      isTracking: isTracking ?? this.isTracking,
      isSimulating: isSimulating ?? this.isSimulating,
      permissionDenied: permissionDenied ?? this.permissionDenied,
      lastError: lastError ?? this.lastError,
      hereData: hereData ?? this.hereData,
      lastFetchUtc: lastFetchUtc ?? this.lastFetchUtc,
      tomTomCompareMph: tomTomCompareMph ?? this.tomTomCompareMph,
      mapboxCompareMph: mapboxCompareMph ?? this.mapboxCompareMph,
      simulatedSpeedMph: simulatedSpeedMph ?? this.simulatedSpeedMph,
      drivingSessionPipelineUpdates:
          drivingSessionPipelineUpdates ?? this.drivingSessionPipelineUpdates,
      simulationRoutePolyline:
          simulationRoutePolyline ?? this.simulationRoutePolyline,
      lastFixLat: lastFixLat ?? this.lastFixLat,
      lastFixLng: lastFixLng ?? this.lastFixLng,
    );
  }
}

class DrivingSessionNotifier extends StateNotifier<DrivingSessionState> {
  DrivingSessionNotifier(this.ref) : super(const DrivingSessionState());

  final Ref ref;

  StreamSubscription<Position>? _sub;
  bool _simulationActive = false;
  LocationProcessor? _processor;
  CompareProvidersService? _compare;
  final MockLocationTester _mockLocationTester = MockLocationTester();

  /// Ordered drain so [AndroidSystemClock.elapsedRealtimeMs] matches fix order (Geolocator Android).
  final List<Position> _geoFixQueue = [];
  bool _geoDrainRunning = false;

  Future<bool> _ensureLocationPermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever ||
        perm == LocationPermission.denied) {
      state = state.copyWith(permissionDenied: true, lastError: 'Location denied');
      return false;
    }
    return true;
  }

  /// Kotlin [MainActivity] [Lifecycle.Event.ON_RESUME] / [ON_PAUSE] / [ON_STOP] via Flutter lifecycle:
  /// - [AppLifecycleState.resumed] → visible (ON_RESUME).
  /// - [AppLifecycleState.paused] / [hidden] → not visible (ON_PAUSE / ON_STOP).
  /// - [AppLifecycleState.inactive] → **no change** (transient; e.g. notification shade — matches Activity staying resumed).
  /// - [AppLifecycleState.detached] → not visible (process teardown).
  void syncAppLifecycle(AppLifecycleState lifecycle) {
    final bool visible;
    switch (lifecycle) {
      case AppLifecycleState.inactive:
        return;
      case AppLifecycleState.resumed:
        visible = true;
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        visible = false;
        break;
    }

    AppForegroundTracker.isMainActivityVisible = visible;
    ref.read(appForegroundVisibleProvider.notifier).state = visible;

    final proc = _processor;
    if (proc == null || !state.isTracking) return;
    final preferencesManager = ref.read(preferencesProvider).preferencesManager;
    if (preferencesManager.alertRunMode != AlertRunMode.normal) {
      proc.setPipelinePaused(false);
      if (_useAndroidFused()) {
        unawaited(FusedDrivingLocation.setPaused(false));
      }
      return;
    }
    proc.setPipelinePaused(!visible);
    if (_useAndroidFused()) {
      unawaited(FusedDrivingLocation.setPaused(!visible));
    }
  }

  void _syncCompareFromCache() {
    final c = _compare;
    if (c == null) return;
    final pm = ref.read(preferencesProvider).preferencesManager;
    if (!pm.isTomTomApiEnabled && !pm.isMapboxApiEnabled) {
      state = state.copyWith(tomTomCompareMph: null, mapboxCompareMph: null);
      return;
    }
    final p = c.peekCachedCompareTomTomMapboxMph();
    state = state.copyWith(
      tomTomCompareMph: p.$1,
      mapboxCompareMph: p.$2,
    );
  }

  /// Kotlin [SpeedAlertService.checkSpeedAlert] — same if/else sequence and predicates (incl. `hasLimit` OK branch).
  void _checkSpeedAlertLikeKotlin(double speedMph, double? limitMph) {
    final pm = ref.read(preferencesProvider).preferencesManager;
    final inForeground = ref.read(appForegroundVisibleProvider);
    final threshold = pm.alertThresholdMph;
    final mode = pm.alertRunMode;
    final lim = limitMph;
    final hasLimit = lim != null && lim > 0;
    final suppressLowSpeedAlerts =
        pm.suppressAlertsWhenUnder15Mph && speedMph < kLowSpeedAlertSuppressBelowMph;
    final isSpeeding = !suppressLowSpeedAlerts &&
        lim != null &&
        lim > 0 &&
        speedMph > lim + threshold;

    final shouldPlayAudible = pm.isAudibleAlertEnabled &&
        isSpeeding &&
        switch (mode) {
          AlertRunMode.normal => inForeground,
          AlertRunMode.backgroundSound => true,
          AlertRunMode.backgroundOverlay => true,
          _ => false,
        };

    developer.log(
      'checkSpeedAlert: speed=$speedMph, limit=$lim, threshold=$threshold, '
      'mode=$mode, inFg=$inForeground, speeding=$isSpeeding, audible=${pm.isAudibleAlertEnabled}',
      name: 'SpeedAlertService',
    );

    if (shouldPlayAudible) {
      developer.log(
        'ALERT: Speed $speedMph mph > Limit $lim + Threshold $threshold',
        name: 'SpeedAlertService',
      );
      unawaited(
        SpeedAlertSoundPlatform.playDebouncedIfEligible(
          preferencesManager: pm,
          appInForeground: inForeground,
        ),
      );
    } else if (hasLimit) {
      developer.log(
        'OK: Speed $speedMph mph <= Limit $lim + Threshold $threshold',
        name: 'SpeedAlertService',
      );
    }

    unawaited(
      OverlayPlatformChannel.sync(
        preferencesManager: pm,
        appInForeground: inForeground,
        speedMph: speedMph,
        limitMph: limitMph,
        isSpeeding: isSpeeding,
      ),
    );
  }

  /// [countDrivingApiSession]: false when pipeline is started only for Testing simulation — Kotlin
  /// does not run [onDrivingSessionStarted] until [ACTION_START_DRIVING_TRACK].
  Future<void> startTracking({bool countDrivingApiSession = true}) async {
    if (!await _ensureLocationPermission()) {
      if (_useAndroidFused()) {
        final pm = ref.read(preferencesProvider).preferencesManager;
        pm.flutterDrivingTrackingActive = false;
        ref.read(prefsRevisionProvider.notifier).state++;
        unawaited(FusedDrivingLocation.stop());
      }
      return;
    }

    await stopRouteSimulation();
    await _sub?.cancel();

    final compare = ref.read(compareProvidersServiceProvider);
    compare.onCacheChanged = () {
      _syncCompareFromCache();
    };
    _compare = compare;

    _processor = LocationProcessor(
      preferencesManager: ref.read(preferencesProvider).preferencesManager,
      speedLimitAggregator: ref.read(speedLimitAggregatorProvider),
      compare: compare,
      onSpeedUpdate: (vehicleMph, limitMph) {
        var d = state.drivingSessionPipelineUpdates;
        if (!_simulationActive && state.isTracking) {
          d++;
        }
        state = state.copyWith(
          speedMph: vehicleMph,
          limitMph: limitMph,
          lastFetchUtc: DateTime.now().toUtc(),
          drivingSessionPipelineUpdates: d,
          hereData: limitMph != null
              ? SpeedLimitData(
                  provider: 'HERE Maps',
                  speedLimitMph: limitMph.round(),
                  confidence: ConfidenceLevel.high,
                  source: 'LocationProcessor',
                )
              : state.hereData,
        );
        _checkSpeedAlertLikeKotlin(vehicleMph, limitMph);
      },
    );
    _processor!.markDrivingSessionStarted();
    unawaited(SpeedDebugLogRouter.startDrivingSession());
    if (countDrivingApiSession) {
      SpeedLimitApiSessionCounter.onDrivingSessionStarted();
    }

    state = state.copyWith(
      isTracking: true,
      permissionDenied: false,
      lastError: null,
      drivingSessionPipelineUpdates: 0,
    );

    if (_useAndroidFused()) {
      _sub = FusedDrivingLocation.positionStream().listen(_onPosition, onError: (Object e) {
        state = state.copyWith(lastError: '$e');
      });
      await FusedDrivingLocation.start();
    } else {
      final stream = Geolocator.getPositionStream(
        locationSettings: _buildLocationSettings(),
      );
      _sub = stream.listen(_onPosition, onError: (Object e) {
        state = state.copyWith(lastError: '$e');
      });
    }

    if (_useAndroidFused()) {
      final pm = ref.read(preferencesProvider).preferencesManager;
      pm.flutterDrivingTrackingActive = true;
      ref.read(prefsRevisionProvider.notifier).state++;
    }
  }

  /// After DKA / engine recreate: if native fused service still runs, rebuild Dart pipeline (Kotlin rebind).
  Future<void> restoreAndroidFusedSessionIfNeeded() async {
    if (!_useAndroidFused()) return;
    if (state.isTracking) return;
    final pm = ref.read(preferencesProvider).preferencesManager;
    if (!pm.flutterDrivingTrackingActive) return;
    final running = await FusedDrivingLocation.isForegroundServiceRunning();
    if (!running) {
      pm.flutterDrivingTrackingActive = false;
      ref.read(prefsRevisionProvider.notifier).state++;
      return;
    }
    await startTracking(countDrivingApiSession: false);
  }

  /// Road-test style simulation: fetch HERE route (Edge or local), then [MockLocationTester]-style fixes.
  /// Does not require “Start driving” first — starts tracking if needed (Kotlin [MainActivity] parity).
  Future<void> startRouteSimulation() async {
    state = state.copyWith(lastError: null);

    if (!state.isTracking || _processor == null) {
      await startTracking(countDrivingApiSession: false);
    }
    if (_processor == null) {
      state = state.copyWith(
        lastError:
            'Cannot start simulation: location pipeline unavailable (permission or session).',
      );
      return;
    }

    _mockLocationTester.cancel();
    _simulationActive = false;
    ref.read(simulationMapAnchorProvider.notifier).state = null;
    if (!_useAndroidFused()) {
      await _sub?.cancel();
      _sub = null;
    }

    // Kotlin: no polyline → abort; never substitute a fake path.
    late final List<GeoCoordinate> routePoints;
    HereSectionSpeedModel? simulationOdSectionModel;
    try {
      final resolved = await resolveSimulationRoute(ref);
      routePoints = resolved.path;
      simulationOdSectionModel = resolved.sectionSpeedModel;
    } catch (e) {
      state = state.copyWith(
        lastError: 'Simulation route error: $e',
      );
      return;
    }
    if (routePoints.length < 2) {
      state = state.copyWith(
        lastError:
            'No simulation route: enable HERE in Settings, valid HERE key, and origin/destination (preset 4 can geocode from custom search). Or use Remote speed API + sign-in.',
      );
      return;
    }

    _processor!.prepareForRoadTestSimulationStart();
    _processor!.primeHereSectionSpeedModelFromSimulationOdRoute(simulationOdSectionModel);

    await SpeedDebugLogRouter.startSimulationSession();
    SpeedLimitApiSessionCounter.onTestStarted();

    if (_useAndroidFused()) {
      await FusedDrivingLocation.setSimulationActive(true);
    }

    _simulationActive = true;
    state = state.copyWith(
      isSimulating: true,
      simulatedSpeedMph: 30,
      simulationRoutePolyline: routePoints,
    );

    _mockLocationTester.start(
      routePoints: routePoints,
      speedMph: () => state.simulatedSpeedMph.toDouble(),
      onPosition: (pos) {
        if (!_simulationActive) return;
        ref.read(simulationMapAnchorProvider.notifier).state =
            (lat: pos.latitude, lng: pos.longitude);
        state = state.copyWith(
          lastFixLat: pos.latitude,
          lastFixLng: pos.longitude,
        );
        _processor?.processNewLocation(pos);
        _syncCompareFromCache();
        scheduleMicrotask(_syncCompareFromCache);
      },
      onRouteCompleted: () {
        unawaited(stopRouteSimulation());
      },
    );
  }

  void adjustSimulatedSpeed(int deltaMph) {
    // Kotlin [MainActivity] onAdjustSpeed: simulatedSpeed += delta (no clamp).
    state = state.copyWith(simulatedSpeedMph: state.simulatedSpeedMph + deltaMph);
  }

  Future<void> stopRouteSimulation() async {
    _mockLocationTester.cancel();
    if (!_simulationActive) return;
    SpeedLimitApiSessionCounter.onTestStopped();
    _simulationActive = false;
    ref.read(simulationMapAnchorProvider.notifier).state = null;
    state = state.copyWith(
      isSimulating: false,
      simulatedSpeedMph: 30,
      speedMph: 0,
      limitMph: null,
      simulationRoutePolyline: const [],
    );
    _syncCompareFromCache();
    _processor?.clearLimitCacheAfterSimulation();
    if (state.isTracking && _processor != null) {
      if (_useAndroidFused()) {
        await FusedDrivingLocation.setSimulationActive(false);
        try {
          final p = await Geolocator.getCurrentPosition(
            locationSettings: AndroidSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 0,
            ),
          );
          _processor?.processNewLocation(p);
          _syncCompareFromCache();
        } catch (_) {}
      } else {
        final stream = Geolocator.getPositionStream(
          locationSettings: _buildLocationSettings(),
        );
        _sub = stream.listen(_onPosition, onError: (Object e) {
          state = state.copyWith(lastError: '$e');
        });
        try {
          final p = await Geolocator.getCurrentPosition(
            locationSettings: _buildLocationSettings(),
          );
          _processor?.processNewLocation(p);
          _syncCompareFromCache();
        } catch (_) {}
      }
    }
  }

  Future<void> stopTracking() async {
    await stopRouteSimulation();
    SpeedLimitApiSessionCounter.onDrivingSessionStopped();
    SpeedDebugLogRouter.stopDrivingSession();
    _geoFixQueue.clear();
    await _sub?.cancel();
    _sub = null;
    if (_useAndroidFused()) {
      await FusedDrivingLocation.setPaused(false);
      await FusedDrivingLocation.setSimulationActive(false);
      await FusedDrivingLocation.stop();
    }
    _processor?.clearLimitCacheAfterSimulation();
    _processor = null;
    _compare?.onCacheChanged = null;
    _compare = null;
    await OverlayPlatformChannel.hide();
    if (_useAndroidFused()) {
      final pm = ref.read(preferencesProvider).preferencesManager;
      pm.flutterDrivingTrackingActive = false;
      ref.read(prefsRevisionProvider.notifier).state++;
    }
    state = const DrivingSessionState();
  }

  void _onPosition(Position pos) {
    if (_simulationActive) return;
    if (_useAndroidFused()) {
      final prov = FusedDrivingLocation.takePendingProvider();
      _deliverPositionToProcessor(
        pos,
        androidElapsedRealtimeNanos: FusedDrivingLocation.takePendingElapsedRealtimeNs(),
        androidLocationProvider: prov.isEmpty ? null : prov,
      );
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      _geoFixQueue.add(pos);
      unawaited(_drainGeoFixQueue());
      return;
    }
    _deliverPositionToProcessor(pos);
  }

  Future<void> _drainGeoFixQueue() async {
    if (_geoDrainRunning) return;
    _geoDrainRunning = true;
    try {
      while (_geoFixQueue.isNotEmpty) {
        final pos = _geoFixQueue.removeAt(0);
        final ns = await AndroidSystemClock.elapsedRealtimeNanos();
        _deliverPositionToProcessor(
          pos,
          androidElapsedRealtimeNanos: ns,
        );
      }
    } finally {
      _geoDrainRunning = false;
      if (_geoFixQueue.isNotEmpty) {
        unawaited(_drainGeoFixQueue());
      }
    }
  }

  /// Kotlin [SpeedAlertService.updateLocation]: last fix on state, then [LocationProcessor.processNewLocation].
  void _deliverPositionToProcessor(
    Position pos, {
    int? androidElapsedRealtimeNanos,
    String? androidLocationProvider,
  }) {
    final p = _processor;
    if (p == null) return;
    state = state.copyWith(
      lastFixLat: pos.latitude,
      lastFixLng: pos.longitude,
    );
    p.processNewLocation(
      pos,
      androidElapsedRealtimeNanos: androidElapsedRealtimeNanos,
      androidLocationProvider: androidLocationProvider,
    );
    _syncCompareFromCache();
  }

  @override
  void dispose() {
    _mockLocationTester.cancel();
    // Kotlin: [SpeedAlertService] can outlive [MainActivity]; do not decrement API session counter here.
    if (state.isTracking) {
      SpeedDebugLogRouter.stopDrivingSession();
    }
    _processor?.setPipelinePaused(true);
    _processor = null;
    _sub?.cancel();
    if (_useAndroidFused()) {
      unawaited(FusedDrivingLocation.setPaused(false));
      unawaited(FusedDrivingLocation.setSimulationActive(false));
      unawaited(FusedDrivingLocation.stop());
    }
    _compare?.onCacheChanged = null;
    _compare = null;
    unawaited(OverlayPlatformChannel.hide());
    super.dispose();
  }

  static bool _useAndroidFused() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Foreground service notification on Android (parity with Kotlin fused updates in background).
  static LocationSettings _buildLocationSettings() {
    if (kIsWeb) {
      return const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      );
    }
    // Kotlin [SpeedAlertService.requestLocationUpdates]: interval 200ms, min 100ms, 0m displacement.
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 200),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Speed Alert Pro',
          notificationText: 'Tracking speed and location',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        activityType: ActivityType.automotiveNavigation,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }
}

final drivingSessionProvider =
    StateNotifierProvider<DrivingSessionNotifier, DrivingSessionState>(
  (ref) => DrivingSessionNotifier(ref),
);
