import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../core/android_location_compat.dart';
import '../core/android_system_clock.dart';

/// Last GPS snapshot fields for CSV correlation with speed-fetch rows.
///
/// Fix age: when [androidElapsedRealtimeNanos] is set, [snapshotAsync] uses
/// `(elapsedRealtimeNanos - fixNs) / 1_000_000` on Android.
class SpeedLimitLoggingContext {
  SpeedLimitLoggingContext._();

  static final String appSessionId = _randomId();

  static String _randomId() {
    const hex = '0123456789abcdef';
    final b = List.generate(12, (_) => hex[math.Random().nextInt(16)]);
    return b.join();
  }

  static double _odometerMetersTotal = 0;
  static double _prevOdometerLat = double.nan;
  static double _prevOdometerLng = double.nan;

  static int? _lastFunctionalClass;

  static int? _lastTomTomMph;
  static int? _lastMapboxMph;
  static String _lastTomTomMphCell = '';
  static String _lastMapboxMphCell = '';
  static String _hereMphCell = '';
  static String _remoteMphCell = '';
  static String _hereAlertResolvePath = '';

  /// Android [SystemClock] nanoseconds at fix time when available.
  static int? _fixElapsedRealtimeNs;

  /// Session monotonic baseline when no Android nanos (iOS / desktop / channel failure before first fix).
  static int? _fixStopwatchMs;

  static final Stopwatch _sessionMono = Stopwatch()..start();

  static void setHereAlertResolvePath(String path) {
    _hereAlertResolvePath = path;
  }

  static String hereAlertPathForCsv() => _hereAlertResolvePath;

  static String formatMphCsvCell(int? mph, bool networkFetch) {
    if (mph == null) return '';
    final s = mph.toString();
    return networkFetch ? '**$s**' : s;
  }

  /// Updates only the TomTom mph columns (independent of Mapbox).
  static void setTomTomMphCell(String trigger, int? mph) {
    _lastTomTomMph = mph;
    _lastTomTomMphCell = formatMphCsvCell(mph, trigger == 'tomtom_fetch');
  }

  /// Updates only the Mapbox mph columns (independent of TomTom).
  static void setMapboxMphCell(String trigger, int? mph) {
    _lastMapboxMph = mph;
    _lastMapboxMphCell = formatMphCsvCell(mph, trigger == 'mapbox_fetch');
  }

  /// HERE provider mph (primary HERE or HERE compare fetch).
  static void setHereMphCell(int? mph, bool fromNetworkFetch) {
    _hereMphCell = mph == null ? '' : formatMphCsvCell(mph, fromNetworkFetch);
  }

  /// Remote / Supabase Edge mph (primary Remote or Remote compare fetch).
  static void setRemoteMphCell(int? mph, bool fromNetworkFetch) {
    _remoteMphCell = mph == null ? '' : formatMphCsvCell(mph, fromNetworkFetch);
  }

  static String hereMphForCsv() => _hereMphCell;

  static String remoteMphForCsv() => _remoteMphCell;

  static String tomTomMphCellForCsv() =>
      _lastTomTomMphCell.isNotEmpty
          ? _lastTomTomMphCell
          : formatMphCsvCell(_lastTomTomMph, false);

  static String mapboxMphCellForCsv() =>
      _lastMapboxMphCell.isNotEmpty
          ? _lastMapboxMphCell
          : formatMphCsvCell(_lastMapboxMph, false);

  static bool _hasFix = false;
  static double _lat = 0;
  static double _lng = 0;
  static double _bearing = double.nan;
  static double _speedMps = double.nan;
  static double _horizontalAccuracy = double.nan;
  static double _altitude = double.nan;
  static double _verticalAccuracy = double.nan;
  static String _provider = '';
  static int _fixTimeUtcMs = 0;

  static void updateRoadFunctionalClass(int? functionalClass) {
    if (functionalClass != null) _lastFunctionalClass = functionalClass;
  }

  static String functionalClassHumanLabel(int fc) {
    final name = switch (fc) {
      1 => 'motorway / freeway',
      2 => 'major highway',
      3 => 'secondary / other major',
      4 => 'main connectivity',
      5 => 'local connectivity',
      6 => 'local road',
      7 => 'minor / very local',
      8 => 'other / access',
      _ => 'class $fc',
    };
    return '$fc ($name)';
  }

  static String functionalClassDisplay() =>
      _lastFunctionalClass != null ? functionalClassHumanLabel(_lastFunctionalClass!) : '';

  static void resetDrivingLogSession() {
    _odometerMetersTotal = 0;
    _prevOdometerLat = double.nan;
    _prevOdometerLng = double.nan;
    _lastFunctionalClass = null;
    _lastTomTomMph = null;
    _lastMapboxMph = null;
    _lastTomTomMphCell = '';
    _lastMapboxMphCell = '';
    _hereMphCell = '';
    _remoteMphCell = '';
    _hereAlertResolvePath = '';
  }

  /// Updates odometer and last-fix fields from a [Position] (and optional Android monotonic anchor).
  static void updateFromPosition(
    Position location, {
    int? androidElapsedRealtimeNanos,
    String? androidLocationProvider,
  }) {
    if (_prevOdometerLat.isFinite && _prevOdometerLng.isFinite) {
      final d = AndroidLocationCompat.distanceBetweenMeters(
        _prevOdometerLat,
        _prevOdometerLng,
        location.latitude,
        location.longitude,
      );
      if (d >= 0.5 && d <= 400.0) {
        _odometerMetersTotal += d;
      }
    }
    _prevOdometerLat = location.latitude;
    _prevOdometerLng = location.longitude;

    _hasFix = true;
    _lat = location.latitude;
    _lng = location.longitude;
    final brg = AndroidLocationCompat.positionBearingIfHasBearing(location);
    _bearing = brg ?? double.nan;
    _speedMps = AndroidLocationCompat.positionHasReportedSpeed(location)
        ? location.speed
        : double.nan;
    _horizontalAccuracy = location.accuracy;
    _altitude = location.altitude;
    _verticalAccuracy = location.altitudeAccuracy;
    if (androidLocationProvider != null && androidLocationProvider.isNotEmpty) {
      _provider = androidLocationProvider;
    } else {
      _provider = '';
    }
    _fixTimeUtcMs = location.timestamp.millisecondsSinceEpoch;

    if (androidElapsedRealtimeNanos != null) {
      _fixElapsedRealtimeNs = androidElapsedRealtimeNanos;
      _fixStopwatchMs = null;
    } else {
      _fixElapsedRealtimeNs = null;
      _fixStopwatchMs = _sessionMono.elapsedMilliseconds;
    }
  }

  /// CSV rows — uses [SystemClock.elapsedRealtimeNanos] when fix used Android monotonic anchor.
  static Future<LoggingSnapshot> snapshotAsync() async {
    if (!_hasFix) return LoggingSnapshot.empty;

    final wallNow = DateTime.now().millisecondsSinceEpoch;
    int ageMs;

    if (_fixElapsedRealtimeNs != null &&
        !kIsWeb &&
        Platform.isAndroid) {
      final nowNs = await AndroidSystemClock.elapsedRealtimeNanos();
      if (nowNs != null) {
        ageMs = ((nowNs - _fixElapsedRealtimeNs!) ~/ 1000000).clamp(0, 1 << 31);
      } else {
        ageMs = (wallNow - _fixTimeUtcMs).clamp(0, 1 << 31);
      }
    } else if (_fixStopwatchMs != null) {
      ageMs = (_sessionMono.elapsedMilliseconds - _fixStopwatchMs!).clamp(0, 1 << 31);
    } else {
      ageMs = (wallNow - _fixTimeUtcMs).clamp(0, 1 << 31);
    }

    return LoggingSnapshot(
      hasFix: true,
      lat: _lat,
      lng: _lng,
      bearingDeg: _bearing.isFinite ? _bearing.toStringAsFixed(1) : '',
      speedMps: _speedMps.isFinite && _speedMps >= 0 ? _speedMps.toStringAsFixed(3) : '',
      horizontalAccuracyM: _horizontalAccuracy.isFinite && _horizontalAccuracy >= 0
          ? _horizontalAccuracy.toStringAsFixed(1)
          : '',
      altitudeM: _altitude.isFinite ? _altitude.toStringAsFixed(1) : '',
      verticalAccuracyM: _verticalAccuracy.isFinite && _verticalAccuracy >= 0
          ? _verticalAccuracy.toStringAsFixed(1)
          : '',
      provider: _provider,
      fixAgeMs: ageMs.toString(),
      roadFunctionalClass: functionalClassDisplay(),
      odometerMeters: _odometerMetersTotal.toStringAsFixed(1),
    );
  }
}

/// Immutable row of logging context for CSV emission (Dart name avoids clash with Riverpod).
class LoggingSnapshot {
  const LoggingSnapshot({
    required this.hasFix,
    required this.lat,
    required this.lng,
    required this.bearingDeg,
    required this.speedMps,
    required this.horizontalAccuracyM,
    required this.altitudeM,
    required this.verticalAccuracyM,
    required this.provider,
    required this.fixAgeMs,
    required this.roadFunctionalClass,
    required this.odometerMeters,
  });

  final bool hasFix;
  final double lat;
  final double lng;
  final String bearingDeg;
  final String speedMps;
  final String horizontalAccuracyM;
  final String altitudeM;
  final String verticalAccuracyM;
  final String provider;
  final String fixAgeMs;
  final String roadFunctionalClass;
  final String odometerMeters;

  static const LoggingSnapshot empty = LoggingSnapshot(
    hasFix: false,
    lat: 0,
    lng: 0,
    bearingDeg: '',
    speedMps: '',
    horizontalAccuracyM: '',
    altitudeM: '',
    verticalAccuracyM: '',
    provider: '',
    fixAgeMs: '',
    roadFunctionalClass: '',
    odometerMeters: '',
  );
}
