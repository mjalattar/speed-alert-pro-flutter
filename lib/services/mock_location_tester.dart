import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../core/android_location_compat.dart';
import '../engine/geo_coordinate.dart';

/// Flutter port of Kotlin [MockLocationTester] — interpolated fixes along route vertices.
// VERIFIED: 1:1 Logic match with Kotlin (segment [distanceTo]/[bearingTo], emit then [delay] 100 ms).
class MockLocationTester {
  /// Kotlin [MockLocationTester.SIMULATION_LOCATION_UPDATE_INTERVAL_MS]
  static const int SIMULATION_LOCATION_UPDATE_INTERVAL_MS = 100;

  bool _simulating = false;
  Future<void>? _loop;

  void cancel() {
    _simulating = false;
  }

  /// [speedMph] read each tick so +/- buttons apply mid-run (Kotlin [updateSimulatedSpeed]).
  void start({
    required List<GeoCoordinate> routePoints,
    required double Function() speedMph,
    required void Function(Position position) onPosition,
    required void Function() onRouteCompleted,
  }) {
    cancel();
    if (routePoints.length < 2) {
      return;
    }
    _simulating = true;
    _loop = _runSimulation(
      routePoints: routePoints,
      speedMph: speedMph,
      onPosition: onPosition,
      onRouteCompleted: onRouteCompleted,
    );
    unawaited(_loop);
  }

  Future<void> _runSimulation({
    required List<GeoCoordinate> routePoints,
    required double Function() speedMph,
    required void Function(Position position) onPosition,
    required void Function() onRouteCompleted,
  }) async {
    var completedNaturally = false;
    try {
      var segmentIndex = 0;
      while (segmentIndex < routePoints.length - 1 && _simulating) {
        final start = routePoints[segmentIndex];
        final end = routePoints[segmentIndex + 1];
        final segmentDistance = AndroidLocationCompat.distanceBetweenMeters(
          start.lat,
          start.lng,
          end.lat,
          end.lng,
        );

        final speedMps = speedMph() * 0.44704;
        final updateIntervalMs = SIMULATION_LOCATION_UPDATE_INTERVAL_MS;
        final distancePerUpdate = speedMps * (updateIntervalMs / 1000.0);

        var distanceCoveredInSegment = 0.0;
        final segmentBearing = AndroidLocationCompat.bearingToDegrees(
          start.lat,
          start.lng,
          end.lat,
          end.lng,
        );

        while (distanceCoveredInSegment < segmentDistance && _simulating) {
          final fraction = segmentDistance > 0
              ? distanceCoveredInSegment / segmentDistance
              : 1.0;
          final interpolatedLat =
              start.lat + (end.lat - start.lat) * fraction;
          final interpolatedLng =
              start.lng + (end.lng - start.lng) * fraction;

          onPosition(
            Position(
              latitude: interpolatedLat,
              longitude: interpolatedLng,
              timestamp: DateTime.now(),
              accuracy: 1,
              altitude: 0,
              altitudeAccuracy: 0,
              heading: segmentBearing,
              headingAccuracy: 1,
              speed: speedMps,
              speedAccuracy: 1,
              isMocked: true,
            ),
          );

          await Future<void>.delayed(
            Duration(milliseconds: updateIntervalMs),
          );
          distanceCoveredInSegment += distancePerUpdate;
        }
        segmentIndex++;
      }
      completedNaturally =
          segmentIndex >= routePoints.length - 1 && routePoints.length >= 2;
    } finally {
      _simulating = false;
      if (completedNaturally) {
        scheduleMicrotask(onRouteCompleted);
      }
    }
  }
}
