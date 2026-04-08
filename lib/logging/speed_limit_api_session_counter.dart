import 'dart:async';

import 'package:flutter/foundation.dart';

import 'speed_debug_log_auto_exporter.dart';

/// Driving / test session hooks for counting speed-related API usage.
class SpeedLimitApiSessionCounter {
  SpeedLimitApiSessionCounter._();

  static bool _testSessionActive = false;
  static bool _drivingSessionActive = false;

  static final ValueNotifier<int> count = ValueNotifier<int>(0);
  static final ValueNotifier<int> drivingSessionRequestCount = ValueNotifier<int>(0);

  /// HERE `router.hereapi.com` routing/speed-span GETs during an active **simulation** test only.
  /// (Testing tab label — excludes TomTom/Mapbox and non-HERE calls.)
  static final ValueNotifier<int> hereRoutingTestSessionCount = ValueNotifier<int>(0);

  /// Same HERE routing count semantics as [hereRoutingTestSessionCount], for an active **driving** session.
  static final ValueNotifier<int> hereRoutingDrivingSessionCount = ValueNotifier<int>(0);

  /// Supabase Edge `speed-limit-remote` POSTs during an active **simulation** test only.
  static final ValueNotifier<int> remoteEdgeTestSessionCount = ValueNotifier<int>(0);

  /// Supabase Edge `speed-limit-remote` POSTs during an active **driving** session.
  static final ValueNotifier<int> remoteEdgeDrivingSessionCount = ValueNotifier<int>(0);

  static void onTestStarted() {
    _testSessionActive = true;
    count.value = 0;
    hereRoutingTestSessionCount.value = 0;
    remoteEdgeTestSessionCount.value = 0;
  }

  static void onTestStopped() {
    _testSessionActive = false;
    unawaited(SpeedDebugLogAutoExporter.exportSimulationSessionEndIfEnabled());
  }

  static void onDrivingSessionStarted() {
    _drivingSessionActive = true;
    drivingSessionRequestCount.value = 0;
    hereRoutingDrivingSessionCount.value = 0;
    remoteEdgeDrivingSessionCount.value = 0;
  }

  static void onDrivingSessionStopped() {
    if (!_drivingSessionActive) return;
    _drivingSessionActive = false;
    unawaited(SpeedDebugLogAutoExporter.exportDrivingSessionEndIfEnabled());
  }

  static void recordIfSessionActive() {
    if (_testSessionActive) {
      count.value = count.value + 1;
    }
    if (_drivingSessionActive) {
      drivingSessionRequestCount.value = drivingSessionRequestCount.value + 1;
    }
  }

  /// Increments HERE routing request counters for simulation and/or driving when active.
  static void recordHereRoutingIfActive() {
    if (_testSessionActive) {
      hereRoutingTestSessionCount.value = hereRoutingTestSessionCount.value + 1;
    }
    if (_drivingSessionActive) {
      hereRoutingDrivingSessionCount.value = hereRoutingDrivingSessionCount.value + 1;
    }
  }

  /// Increments Remote Edge request counters for simulation and/or driving when active.
  static void recordRemoteEdgeIfActive() {
    if (_testSessionActive) {
      remoteEdgeTestSessionCount.value = remoteEdgeTestSessionCount.value + 1;
    }
    if (_drivingSessionActive) {
      remoteEdgeDrivingSessionCount.value = remoteEdgeDrivingSessionCount.value + 1;
    }
  }
}
