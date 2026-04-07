import 'dart:async';

import 'package:flutter/foundation.dart';

import 'speed_debug_log_auto_exporter.dart';

/// Kotlin [SpeedLimitApiSessionCounter] — request counts per session.
class SpeedLimitApiSessionCounter {
  SpeedLimitApiSessionCounter._();

  static bool _testSessionActive = false;
  static bool _drivingSessionActive = false;

  static final ValueNotifier<int> count = ValueNotifier<int>(0);
  static final ValueNotifier<int> drivingSessionRequestCount = ValueNotifier<int>(0);

  /// HERE `router.hereapi.com` routing/speed-span GETs during an active **simulation** test only.
  /// (Testing tab label — excludes TomTom/Mapbox and non-HERE calls.)
  static final ValueNotifier<int> hereRoutingTestSessionCount = ValueNotifier<int>(0);

  static void onTestStarted() {
    _testSessionActive = true;
    count.value = 0;
    hereRoutingTestSessionCount.value = 0;
  }

  static void onTestStopped() {
    _testSessionActive = false;
    unawaited(SpeedDebugLogAutoExporter.exportSimulationSessionEndIfEnabled());
  }

  static void onDrivingSessionStarted() {
    _drivingSessionActive = true;
    drivingSessionRequestCount.value = 0;
  }

  static void onDrivingSessionStopped() {
    _drivingSessionActive = false;
  }

  static void recordIfSessionActive() {
    if (_testSessionActive) {
      count.value = count.value + 1;
    }
    if (_drivingSessionActive) {
      drivingSessionRequestCount.value = drivingSessionRequestCount.value + 1;
    }
  }

  static void recordHereRoutingTestIfActive() {
    if (_testSessionActive) {
      hereRoutingTestSessionCount.value = hereRoutingTestSessionCount.value + 1;
    }
  }
}
