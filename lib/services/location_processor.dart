// PROJECT_STATUS: 100% VERIFIED_MIRROR

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../config/app_config.dart';
import '../core/android_location_compat.dart';
import '../engine/cross_track_geometry.dart';
import '../engine/geo_bearing.dart';
import '../engine/gps_trajectory_buffer.dart';
import '../logging/speed_fetch_debug_logger.dart';
import '../logging/speed_limit_api_request_logger.dart';
import '../engine/annotation_section_speed_model.dart';
import '../engine/here_section_speed_model.dart';
import '../engine/section_walk_along_continuity.dart';
import '../engine/speed_limit_gates.dart';
import '../engine/speed_limit_stabilizer.dart';
import '../models/road_segment.dart';
import '../models/speed_limit_data.dart';
import '../logging/speed_limit_logging_context.dart';
import 'compare_providers_service.dart';
import 'preferences_manager.dart';
import 'speed_limit_aggregator.dart';

/// Flutter port of Android [LocationProcessor].
///
/// **MECHANICAL_PARITY (Kotlin `LocationProcessor.kt` private thresholds):**
/// `RELAXED_FIRST_FETCH_SUSTAINED_MS` 800, `SUSTAINED_DRIVING_MS` 2500,
/// `RELAXED_FIRST_COMPARE_FETCH_SUSTAINED_MS` 0, `MIN_DISTANCE_CHANGE_METERS` 480,
/// `MIN_HEADING_CHANGE_DEGREES` 45, `MIN_DISTANCE_CHANGE_METERS_REMOTE` 100,
/// `MIN_HEADING_CHANGE_DEGREES_REMOTE` 22, `MIN_DISPLACEMENT_NOISE_METERS` 10,
/// `STATIONARY_SPEED_MPS` 0.45, `STATIONARY_MAX_DISTANCE_FROM_LAST_FETCH_M` 20,
/// `STATIONARY_DISPLAY_FREEZE_MPS` 2.24, `DRIVING_MIN_MPH_FOR_FETCH` 9,
/// `MIN_DISPLACEMENT_SINCE_FETCH_M` 100, `MIN_HEADING_CHANGE_FOR_FETCH_DEG` 45,
/// `TOMTOM_NETWORK_MIN_DISPLACEMENT_M` 480, `TOMTOM_NETWORK_MIN_HEADING_CHANGE_DEG` 45,
/// `TOMTOM_ALONG_POLYLINE_MAX_CROSS_TRACK_M` 72, `TOMTOM_ALONG_POLYLINE_PAST_END_BUFFER_M` 90,
/// `MAPBOX_NETWORK_MIN_DISPLACEMENT_M` 480, `MAPBOX_NETWORK_MIN_HEADING_CHANGE_DEG` 45,
/// `MAPBOX_ALONG_POLYLINE_MAX_CROSS_TRACK_M` 70, `MAPBOX_ALONG_POLYLINE_PAST_END_BUFFER_M` 88,
/// `HEADING_UTURN_MIN_MPH` 12, `U_TURN_HEADING_DELTA_DEG` 125,
/// `MODERATE_TURN_HEADING_DELTA_DEG` 45, `MODERATE_TURN_HEADING_COOLDOWN_MS` 4000 — same as Dart `static const` values below.
///
/// **Primary (HERE):** [HereSectionSpeedModel] / sticky segment / network — [CrossTrackGeometry] applies to HERE
/// polylines first. Section-walk uses the span at the current along-polyline position each tick (no
/// multi-tick vote window; Android Kotlin still uses `SectionWalkMatchVoteBuffer`).
/// The debounced alert limit is assigned only in [_applyHereResolvedLimit] from HERE inputs.
///
/// **Comparison (TomTom / Mapbox):** [AnnotationSectionSpeedModel] via [compare] only; [_enqueueCompareSideEffectsForLocationTick]
/// never writes the alert limit. Async compare fetches are triple-locked like Kotlin.
class LocationProcessor {
  LocationProcessor({
    required this.preferencesManager,
    required this.speedLimitAggregator,
    required this.compare,
    required this.onSpeedUpdate,
  });

  final PreferencesManager preferencesManager;
  final SpeedLimitAggregator speedLimitAggregator;
  final CompareProvidersService compare;

  /// Kotlin [SpeedAlertService] callback after [_currentSpeed] / [_currentSpeedLimit] — implementor runs
  /// [checkSpeedAlert] (state, audible, overlay) in one place.
  final void Function(double vehicleSpeedMph, double? speedLimitMph) onSpeedUpdate;

  bool _pipelinePaused = false;

  Position? _lastApiFetchLocation;
  double? _currentSpeedLimitMph;
  int _speedFetchGeneration = 0;

  final _speedLimitStabilizer = SpeedLimitStabilizer(windowSize: SpeedLimitStabilizer.defaultWindow);
  final _materialChangeGate = SpeedLimitMaterialChangeGate();
  final _smallUpGate = SpeedLimitSmallUpGate();
  final _moderateDownGate = SpeedLimitModerateDownGate();

  String? _lastRouteContextKey;
  String? _lastHereSegmentKey;
  int? _lastHereRawMph;

  bool _logHeadingInvalidateForDisplayTrace = false;
  int? _lastLoggedDisplayLimitMph;

  RoadSegment? _stickyRoadSegment;
  HereSectionSpeedModel? _hereSectionSpeedModel;

  final _sectionWalkAlongContinuity = SectionWalkAlongContinuity();

  AnnotationSectionSpeedModel? _tomtomCompareRouteModel;
  AnnotationSectionSpeedModel? _mapboxCompareRouteModel;

  final _downwardLimitDebouncer = DownwardLimitDebouncer();

  double? _lastRouteHeadingDeg;
  int _lastModerateHeadingInvalidateUtcMs = 0;
  bool _forceImmediateLimitCommit = false;

  Position? _lastProcessedLocation;

  final _gpsTrajectoryBuffer = GpsTrajectoryBuffer(capacity: 5);

  int _drivingSustainedStartUtcMs = 0;
  int _tomtomCompareSustainedStartUtcMs = 0;
  int _mapboxCompareSustainedStartUtcMs = 0;

  bool _pendingRelaxedFirstFetch = false;
  bool _pendingRelaxedFirstTomTomCompareFetch = true;
  bool _pendingRelaxedFirstMapboxCompareFetch = true;

  bool _hereFetchInFlight = false;
  Position? _pendingFetchLocation;
  // Kotlin [pendingFetchSpeedMph]: stored while fetch in flight; chained retry uses fresh [effectiveSpeedMpsAndMph].
  // ignore: unused_field
  double? _pendingFetchSpeedMph;

  bool _tomtomCompareFetchInFlight = false;
  Position? _pendingTomTomCompareFetchLocation;
  Position? _lastTomTomCompareFetchLocation;

  bool _mapboxCompareFetchInFlight = false;
  Position? _pendingMapboxCompareFetchLocation;
  Position? _lastMapboxCompareFetchLocation;

  bool useLocalHereForAlerts() =>
      !AppConfig.useRemoteHere || !preferencesManager.useRemoteSpeedApi;

  bool shouldApplyLocalStabilizer() =>
      useLocalHereForAlerts() && preferencesManager.useLocalSpeedStabilizer;

  (int?, int?) _comparePeekMphForLogs() {
    if (!preferencesManager.isTomTomApiEnabled &&
        !preferencesManager.isMapboxApiEnabled) {
      return (null, null);
    }
    return compare.peekCachedCompareTomTomMapboxMph();
  }

  void setPipelinePaused(bool paused) {
    _pipelinePaused = paused;
    if (paused) {
      _speedFetchGeneration++;
      _lastProcessedLocation = null;
      _tomtomCompareSustainedStartUtcMs = 0;
      _mapboxCompareSustainedStartUtcMs = 0;
      _hereFetchInFlight = false;
      _pendingFetchLocation = null;
      _pendingFetchSpeedMph = null;
      _tomtomCompareFetchInFlight = false;
      _pendingTomTomCompareFetchLocation = null;
      _mapboxCompareFetchInFlight = false;
      _pendingMapboxCompareFetchLocation = null;
      _tomtomCompareRouteModel = null;
      _mapboxCompareRouteModel = null;
    }
  }

  void markDrivingSessionStarted() {
    _pendingRelaxedFirstFetch = true;
    _pendingRelaxedFirstTomTomCompareFetch = true;
    _pendingRelaxedFirstMapboxCompareFetch = true;
    _lastProcessedLocation = null;
  }

  void prepareForRoadTestSimulationStart() {
    _resetSessionState(
      relaxedFirstFetch: true,
      resetDrivingLogSession: false,
    );
  }

  /// After [prepareForRoadTestSimulationStart], seed HERE section-walk state from the same O–D route
  /// response used for the simulation polyline (Kotlin [MainActivity]: one `getSpeedLimit` / Edge route
  /// for map; processor then resolves limits along that geometry instead of a divergent alert leg).
  void primeHereSectionSpeedModelFromSimulationOdRoute(HereSectionSpeedModel? model) {
    if (model == null) return;
    _hereSectionSpeedModel = model;
    _sectionWalkAlongContinuity.reset();
  }

  void clearLimitCacheAfterSimulation() {
    _resetSessionState(
      relaxedFirstFetch: false,
      resetDrivingLogSession: true,
    );
  }

  // VERIFIED: 1:1 Logic match with Kotlin [prepareForRoadTestSimulationStart] /
  // [clearLimitCacheAfterSimulation] field order (generation → relaxed → sustained → optional log reset → …).
  void _resetSessionState({
    required bool relaxedFirstFetch,
    required bool resetDrivingLogSession,
  }) {
    _speedFetchGeneration++;
    _pendingRelaxedFirstFetch = relaxedFirstFetch;
    _drivingSustainedStartUtcMs = 0;
    _tomtomCompareSustainedStartUtcMs = 0;
    _mapboxCompareSustainedStartUtcMs = 0;
    if (resetDrivingLogSession) {
      SpeedLimitLoggingContext.resetDrivingLogSession();
    }
    _lastProcessedLocation = null;
    _lastApiFetchLocation = null;
    _lastTomTomCompareFetchLocation = null;
    _lastMapboxCompareFetchLocation = null;
    _pendingRelaxedFirstTomTomCompareFetch = true;
    _pendingRelaxedFirstMapboxCompareFetch = true;
    _currentSpeedLimitMph = null;
    _stickyRoadSegment = null;
    _hereSectionSpeedModel = null;
    _sectionWalkAlongContinuity.reset();
    _tomtomCompareRouteModel = null;
    _mapboxCompareRouteModel = null;
    _downwardLimitDebouncer.reset();
    _lastRouteHeadingDeg = null;
    _lastModerateHeadingInvalidateUtcMs = 0;
    _forceImmediateLimitCommit = false;
    _hereFetchInFlight = false;
    _pendingFetchLocation = null;
    _pendingFetchSpeedMph = null;
    _tomtomCompareFetchInFlight = false;
    _pendingTomTomCompareFetchLocation = null;
    _mapboxCompareFetchInFlight = false;
    _pendingMapboxCompareFetchLocation = null;
    compare.clearCompareProviderStickyCache();
    _lastRouteContextKey = null;
    _lastHereSegmentKey = null;
    _lastHereRawMph = null;
    _speedLimitStabilizer.clear();
    _materialChangeGate.reset();
    _smallUpGate.reset();
    _moderateDownGate.reset();
    _gpsTrajectoryBuffer.clear();
    _logHeadingInvalidateForDisplayTrace = false;
    _lastLoggedDisplayLimitMph = null;
  }

  /// Kotlin [processNewLocation].
  void processNewLocation(
    Position location, {
    int? androidElapsedRealtimeNanos,
    String? androidLocationProvider,
  }) {
    if (_pipelinePaused) return;
    processNewLocationInner(
      location,
      androidElapsedRealtimeNanos: androidElapsedRealtimeNanos,
      androidLocationProvider: androidLocationProvider,
    );
  }

  /// Kotlin [processNewLocationInner].
  void processNewLocationInner(
    Position location, {
    int? androidElapsedRealtimeNanos,
    String? androidLocationProvider,
  }) {
    try {
      processNewLocationInnerBody(
        location,
        androidElapsedRealtimeNanos: androidElapsedRealtimeNanos,
        androidLocationProvider: androidLocationProvider,
      );
    } finally {
      _lastProcessedLocation = location;
    }
  }

  /// Kotlin [LocationProcessor.processNewLocationInnerBody] lines 240–242: TomTom/Mapbox **compare** enqueue +
  /// along-polyline cache refresh. **Never** assigns [_currentSpeedLimitMph] — only [_applyHereResolvedLimit] does.
  void _enqueueCompareSideEffectsForLocationTick(
    Position location,
    double rawMph,
    double? headingForPolyline,
  ) {
    unawaited(
      _maybeRequestTomTomCompareFetch(location, rawMph, headingForPolyline),
    );
    unawaited(
      _maybeRequestMapboxCompareFetch(location, rawMph, headingForPolyline),
    );
    _applyCompareRouteModelsAlongPolyline(location, headingForPolyline);
  }

  /// Kotlin [LocationProcessor.processNewLocationInnerBody].
  // VERIFIED: 1:1 Logic match with Kotlin (same call order: speed → anchors → traj add → logging → heading → …).
  void processNewLocationInnerBody(
    Position location, {
    int? androidElapsedRealtimeNanos,
    String? androidLocationProvider,
  }) {
    final speedPair = _effectiveSpeedMpsAndMph(location);
    final speedMps = speedPair.$1;
    final rawMph = speedPair.$2;

    final displayMph = rawMph;
    _updateSustainedDrivingAnchor(location, rawMph);
    _updateTomTomCompareSustainedAnchor(location, rawMph);
    _updateMapboxCompareSustainedAnchor(location, rawMph);

    _gpsTrajectoryBuffer.add(location, speedMps);
    SpeedLimitLoggingContext.updateFromPosition(
      location,
      androidElapsedRealtimeNanos: androidElapsedRealtimeNanos,
      androidLocationProvider: androidLocationProvider,
    );

    final trajBearing = _gpsTrajectoryBuffer.bearingDegreesForMatching();
    final smoothedBearing =
        _gpsTrajectoryBuffer.bearingDegreesSmoothedForMatching();
    final userHeading =
        AndroidLocationCompat.positionBearingIfHasBearing(location) ??
            trajBearing;
    final headingForPolyline = smoothedBearing ?? userHeading;

    _maybeInvalidateForSharpHeadingChange(userHeading, rawMph, location.timestamp.millisecondsSinceEpoch);
    // Sharp-turn invalidation clears compare sustained anchors. Re-arm immediately so TomTom/Mapbox
    // gates see the current fix as sustained driving in the same tick (otherwise compare often never
    // ran during simulation when bearing jumped each route vertex).
    _updateTomTomCompareSustainedAnchor(location, rawMph);
    _updateMapboxCompareSustainedAnchor(location, rawMph);
    _enqueueCompareSideEffectsForLocationTick(
      location,
      rawMph,
      headingForPolyline,
    );

    final routeModel = _hereSectionSpeedModel;
    if (routeModel != null && !routeModel.isExpired()) {
      final proj = CrossTrackGeometry.projectOntoPolylineForMatching(
        location.latitude,
        location.longitude,
        routeModel.geometry,
        headingForPolyline,
      );
      if (proj != null &&
          CrossTrackGeometry.isSectionWalkProjectionValid(
            proj,
            routeModel.geometry,
            headingForPolyline,
          )) {
        final alongRaw = proj.alongMeters;
        final along = _sectionWalkAlongContinuity.clampAlong(alongRaw, location);
        final resolved = routeModel.speedLimitDataAtAlong(along);
        final mph = resolved.speedLimitMph;
        if (mph != null) {
          _applyHereResolvedLimit(
            location: location,
            vehicleSpeedMph: displayMph,
            rawMph: mph,
            segmentKey: resolved.segmentKey,
            functionalClass: resolved.functionalClass,
            logCompareRow: false,
            hereTelemetry: null,
            logFields: null,
            hereLimitFromNetworkFetch: false,
            hereResolvePath: 'section_walk',
          );
          return;
        }
      } else {
        _sectionWalkAlongContinuity.reset();
        _hereSectionSpeedModel = null;
      }
    }

    final seg = _stickyRoadSegment;
    if (seg != null &&
        !seg.isExpired() &&
        CrossTrackGeometry.isUserOnSegment(
          location.latitude,
          location.longitude,
          seg,
          headingForPolyline,
        )) {
      _applyHereResolvedLimit(
        location: location,
        vehicleSpeedMph: displayMph,
        rawMph: seg.speedLimitMph.round(),
        segmentKey: seg.linkId,
        functionalClass: seg.functionalClass,
        logCompareRow: false,
        hereTelemetry: null,
        logFields: null,
        hereLimitFromNetworkFetch: false,
        hereResolvePath: 'sticky',
      );
      return;
    }

    if (speedMps < STATIONARY_DISPLAY_FREEZE_MPS &&
        AndroidLocationCompat.positionHasReportedSpeed(location) &&
        (_stickyRoadSegment != null || _hereSectionSpeedModel != null)) {
      final lim = _currentSpeedLimitMph ?? _stickyRoadSegment?.speedLimitMph;
      if (lim == null) return;
      SpeedLimitLoggingContext.setHereAlertResolvePath('stationary_hold');
      onSpeedUpdate(displayMph, lim);
      return;
    }

    if (useLocalHereForAlerts()) {
      _maybeRequestHereFetch(location, rawMph, displayMph);
      return;
    }

    if (_shouldFetchNewSpeedLimit(location, speedMps)) {
      if (_shouldTriggerHereSpeedLimitFetch(location, rawMph)) {
        _maybeRequestHereFetch(location, rawMph, displayMph);
      } else {
        _emitSpeedUiOnly(displayMph, 'here_fetch_gated');
      }
    } else {
      SpeedLimitLoggingContext.setHereAlertResolvePath('remote_cache_idle');
      onSpeedUpdate(displayMph, _currentSpeedLimitMph);
    }
  }

  // VERIFIED: 1:1 Logic match with Kotlin [speedMpsAndRawMph].
  (double, double) _speedMpsAndRawMph(Position location) {
    if (AndroidLocationCompat.positionHasReportedSpeed(location) &&
        location.speed >= 0) {
      final mps = location.speed;
      return (mps, mps * 2.23694);
    }
    return (0.0, 0.0);
  }

  // VERIFIED: 1:1 Logic match with Kotlin [effectiveSpeedMpsAndMph]
  // (`(time−time)/1000`, [Location.distanceTo], `coerceIn` on inferred m/s).
  (double, double) _effectiveSpeedMpsAndMph(Position location) {
    final device = _speedMpsAndRawMph(location);
    if (AndroidLocationCompat.positionHasReportedSpeed(location) &&
        device.$1 >= SPEED_TRUST_MPS) {
      return device;
    }
    final last = _lastProcessedLocation;
    if (last != null) {
      final t = location.timestamp.millisecondsSinceEpoch;
      final t0 = last.timestamp.millisecondsSinceEpoch;
      if (t >= t0) {
        final dtSec = (t - t0) / 1000.0;
        if (dtSec >= MIN_DT_INFER_SEC && dtSec <= MAX_DT_INFER_SEC) {
          final dist = AndroidLocationCompat.distanceBetweenMeters(
            last.latitude,
            last.longitude,
            location.latitude,
            location.longitude,
          );
          var inferredMps =
              (dist / dtSec).clamp(0.0, MAX_INFERRED_MPS.toDouble());
          if (inferredMps >= SPEED_TRUST_MPS) {
            return (inferredMps, inferredMps * 2.23694);
          }
        }
      }
    }
    return device;
  }

  void _updateSustainedDrivingAnchor(Position location, double rawMph) {
    if (rawMph >= DRIVING_MIN_MPH_FOR_FETCH) {
      if (_drivingSustainedStartUtcMs == 0) {
        _drivingSustainedStartUtcMs = location.timestamp.millisecondsSinceEpoch;
      }
    } else {
      _drivingSustainedStartUtcMs = 0;
    }
  }

  void _updateTomTomCompareSustainedAnchor(Position location, double rawMph) {
    if (!preferencesManager.isTomTomApiEnabled) {
      _tomtomCompareSustainedStartUtcMs = 0;
      return;
    }
    if (rawMph >= DRIVING_MIN_MPH_FOR_FETCH) {
      if (_tomtomCompareSustainedStartUtcMs == 0) {
        _tomtomCompareSustainedStartUtcMs = location.timestamp.millisecondsSinceEpoch;
      }
    } else {
      _tomtomCompareSustainedStartUtcMs = 0;
    }
  }

  void _updateMapboxCompareSustainedAnchor(Position location, double rawMph) {
    if (!preferencesManager.isMapboxApiEnabled) {
      _mapboxCompareSustainedStartUtcMs = 0;
      return;
    }
    if (rawMph >= DRIVING_MIN_MPH_FOR_FETCH) {
      if (_mapboxCompareSustainedStartUtcMs == 0) {
        _mapboxCompareSustainedStartUtcMs = location.timestamp.millisecondsSinceEpoch;
      }
    } else {
      _mapboxCompareSustainedStartUtcMs = 0;
    }
  }

  bool _sustainedDrivingEligible(Position location, double rawMph) {
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (_drivingSustainedStartUtcMs == 0) return false;
    final requiredMs = _pendingRelaxedFirstFetch
        ? RELAXED_FIRST_FETCH_SUSTAINED_MS
        : SUSTAINED_DRIVING_MS;
    return (location.timestamp.millisecondsSinceEpoch - _drivingSustainedStartUtcMs) >=
        requiredMs;
  }

  bool _sufficientDisplacementSinceLastFetch(Position location) {
    final last = _lastApiFetchLocation;
    if (last == null) return true;
    if (AndroidLocationCompat.distanceBetweenMeters(
          last.latitude,
          last.longitude,
          location.latitude,
          location.longitude,
        ) >=
        MIN_DISPLACEMENT_SINCE_FETCH_M) {
      return true;
    }
    final b1 = AndroidLocationCompat.positionBearingIfHasBearing(location);
    final b2 = AndroidLocationCompat.positionBearingIfHasBearing(last);
    if (b1 != null &&
        b2 != null &&
        smallestBearingDeltaDeg(b1, b2) >= MIN_HEADING_CHANGE_FOR_FETCH_DEG) {
      return true;
    }
    return false;
  }

  bool _shouldTriggerHereSpeedLimitFetch(Position location, double rawMph) {
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (!_sustainedDrivingEligible(location, rawMph)) return false;
    if (!_sufficientDisplacementSinceLastFetch(location)) return false;
    return true;
  }

  void _emitSpeedUiOnly(double displayMph, [String hereAlertPath = 'cached_ui']) {
    SpeedLimitLoggingContext.setHereAlertResolvePath(hereAlertPath);
    onSpeedUpdate(displayMph, _currentSpeedLimitMph);
  }

  void _maybeRequestHereFetch(Position location, double rawMph, double displayMph) {
    if (!_shouldTriggerHereSpeedLimitFetch(location, rawMph)) {
      _emitSpeedUiOnly(displayMph, 'here_fetch_gated');
      return;
    }
    _enqueueHereFetch(location, displayMph);
  }

  String _routeContextKey(int? functionalClass, String? segmentKey) {
    if (functionalClass != null) return 'fc:$functionalClass';
    if (segmentKey != null) return 'seg:$segmentKey';
    return 'na';
  }

  bool _shouldFetchNewSpeedLimit(Position currentLocation, double effectiveMps) {
    final lastLoc = _lastApiFetchLocation;
    if (lastLoc == null) return true;
    final distance = AndroidLocationCompat.distanceBetweenMeters(
      lastLoc.latitude,
      lastLoc.longitude,
      currentLocation.latitude,
      currentLocation.longitude,
    );

    if (_currentSpeedLimitMph != null &&
        effectiveMps < STATIONARY_SPEED_MPS &&
        distance < STATIONARY_MAX_DISTANCE_FROM_LAST_FETCH_M) {
      return false;
    }

    if (distance < MIN_DISPLACEMENT_NOISE_METERS) {
      return false;
    }

    final headingChange = () {
      final b1 = AndroidLocationCompat.positionBearingIfHasBearing(currentLocation);
      final b2 = AndroidLocationCompat.positionBearingIfHasBearing(lastLoc);
      if (b1 != null && b2 != null) {
        return smallestBearingDeltaDeg(b1, b2);
      }
      return 0.0;
    }();

    final minDist = useLocalHereForAlerts()
        ? MIN_DISTANCE_CHANGE_METERS
        : MIN_DISTANCE_CHANGE_METERS_REMOTE;
    final minHeading = useLocalHereForAlerts()
        ? MIN_HEADING_CHANGE_DEGREES
        : MIN_HEADING_CHANGE_DEGREES_REMOTE;
    return distance >= minDist || headingChange >= minHeading;
  }

  void _maybeInvalidateForSharpHeadingChange(
    double? userHeading,
    double rawMph,
    int locationTimeUtcMs,
  ) {
    if (rawMph < HEADING_UTURN_MIN_MPH) return;
    if (userHeading == null || !userHeading.isFinite) return;
    final prev = _lastRouteHeadingDeg;
    if (prev != null && prev.isFinite) {
      final delta = smallestBearingDeltaDeg(userHeading, prev);
      if (delta >= U_TURN_HEADING_DELTA_DEG) {
        _invalidateRouteGeometryForSharpTurn();
        _lastModerateHeadingInvalidateUtcMs = locationTimeUtcMs;
      } else if (delta >= MODERATE_TURN_HEADING_DELTA_DEG) {
        // Kotlin: `(locationTimeUtcMs - lastModerateHeadingInvalidateUtcMs).coerceAtLeast(0L)`
        final sinceLastModerate = _lastModerateHeadingInvalidateUtcMs == 0
            ? AndroidLocationCompat.kotlinLongMaxValue
            : (locationTimeUtcMs - _lastModerateHeadingInvalidateUtcMs)
                .clamp(0, 1 << 62);
        if (sinceLastModerate >= MODERATE_TURN_HEADING_COOLDOWN_MS) {
          _invalidateRouteGeometryForSharpTurn();
          _lastModerateHeadingInvalidateUtcMs = locationTimeUtcMs;
        }
      }
    }
    if (userHeading.isFinite && rawMph >= 5) {
      _lastRouteHeadingDeg = userHeading;
    }
  }

  bool _tomtomCompareSustainedEligible(Position location, double rawMph) {
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (_tomtomCompareSustainedStartUtcMs == 0) return false;
    final requiredMs = _pendingRelaxedFirstTomTomCompareFetch
        ? RELAXED_FIRST_COMPARE_FETCH_SUSTAINED_MS
        : SUSTAINED_DRIVING_MS;
    return (location.timestamp.millisecondsSinceEpoch - _tomtomCompareSustainedStartUtcMs) >=
        requiredMs;
  }

  bool _mapboxCompareSustainedEligible(Position location, double rawMph) {
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (_mapboxCompareSustainedStartUtcMs == 0) return false;
    final requiredMs = _pendingRelaxedFirstMapboxCompareFetch
        ? RELAXED_FIRST_COMPARE_FETCH_SUSTAINED_MS
        : SUSTAINED_DRIVING_MS;
    return (location.timestamp.millisecondsSinceEpoch - _mapboxCompareSustainedStartUtcMs) >=
        requiredMs;
  }

  bool _tomtomCompareHasUsableRouteCache() {
    final m = _tomtomCompareRouteModel;
    return m != null && !m.isExpired();
  }

  bool _mapboxCompareHasUsableRouteCache() {
    final m = _mapboxCompareRouteModel;
    return m != null && !m.isExpired();
  }

  bool _shouldTriggerTomTomCompareFetch(Position location, double rawMph) {
    if (!preferencesManager.isTomTomApiEnabled) return false;
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (!_tomtomCompareSustainedEligible(location, rawMph)) return false;
    final minDisp = _tomtomCompareHasUsableRouteCache()
        ? TOMTOM_NETWORK_MIN_DISPLACEMENT_M
        : MIN_DISPLACEMENT_SINCE_FETCH_M;
    return _sufficientDisplacementSinceLastForNetworkFetch(
      location,
      _lastTomTomCompareFetchLocation,
      minDisp,
      TOMTOM_NETWORK_MIN_HEADING_CHANGE_DEG,
    );
  }

  bool _shouldTriggerMapboxCompareFetch(Position location, double rawMph) {
    if (!preferencesManager.isMapboxApiEnabled) return false;
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (!_mapboxCompareSustainedEligible(location, rawMph)) return false;
    final minDisp = _mapboxCompareHasUsableRouteCache()
        ? MAPBOX_NETWORK_MIN_DISPLACEMENT_M
        : MIN_DISPLACEMENT_SINCE_FETCH_M;
    return _sufficientDisplacementSinceLastForNetworkFetch(
      location,
      _lastMapboxCompareFetchLocation,
      minDisp,
      MAPBOX_NETWORK_MIN_HEADING_CHANGE_DEG,
    );
  }

  bool _sufficientDisplacementSinceLastForNetworkFetch(
    Position location,
    Position? last,
    double minDisplacementMeters,
    double minHeadingChangeDeg,
  ) {
    if (last == null) return true;
    if (AndroidLocationCompat.distanceBetweenMeters(
          last.latitude,
          last.longitude,
          location.latitude,
          location.longitude,
        ) >=
        minDisplacementMeters) {
      return true;
    }
    final b1 = AndroidLocationCompat.positionBearingIfHasBearing(location);
    final b2 = AndroidLocationCompat.positionBearingIfHasBearing(last);
    if (b1 != null &&
        b2 != null &&
        smallestBearingDeltaDeg(b1, b2) >= minHeadingChangeDeg) {
      return true;
    }
    return false;
  }

  Future<void> _maybeRequestTomTomCompareFetch(
    Position location,
    double rawMph,
    double? headingDeg,
  ) async {
    if (!_shouldTriggerTomTomCompareFetch(location, rawMph)) return;
    await _enqueueTomTomCompareFetch(location, headingDeg);
  }

  Future<void> _maybeRequestMapboxCompareFetch(
    Position location,
    double rawMph,
    double? headingDeg,
  ) async {
    if (!_shouldTriggerMapboxCompareFetch(location, rawMph)) return;
    await _enqueueMapboxCompareFetch(location, headingDeg);
  }

  void _applyCompareRouteModelsAlongPolyline(
    Position location,
    double? headingForPolyline,
  ) {
    final tm = _tomtomCompareRouteModel;
    if (tm != null && !tm.isExpired()) {
      if (CrossTrackGeometry.isUserOnPolylineForAlongResolve(
        location.latitude,
        location.longitude,
        tm.geometry,
        maxCrossTrackM: TOMTOM_ALONG_POLYLINE_MAX_CROSS_TRACK_M,
        pastEndBufferM: TOMTOM_ALONG_POLYLINE_PAST_END_BUFFER_M,
        userHeadingDeg: headingForPolyline,
      )) {
        final along = CrossTrackGeometry.alongPolylineMetersForMatching(
          location.latitude,
          location.longitude,
          tm.geometry,
          headingForPolyline,
        );
        compare.publishTomTomCompareFromAlong(tm.speedLimitDataAtAlong(along));
      } else {
        _tomtomCompareRouteModel = null;
      }
    }
    final mb = _mapboxCompareRouteModel;
    if (mb != null && !mb.isExpired()) {
      if (CrossTrackGeometry.isUserOnPolylineForAlongResolve(
        location.latitude,
        location.longitude,
        mb.geometry,
        maxCrossTrackM: MAPBOX_ALONG_POLYLINE_MAX_CROSS_TRACK_M,
        pastEndBufferM: MAPBOX_ALONG_POLYLINE_PAST_END_BUFFER_M,
        userHeadingDeg: headingForPolyline,
      )) {
        final along = CrossTrackGeometry.alongPolylineMetersForMatching(
          location.latitude,
          location.longitude,
          mb.geometry,
          headingForPolyline,
        );
        compare.publishMapboxCompareFromAlong(mb.speedLimitDataAtAlong(along));
      } else {
        _mapboxCompareRouteModel = null;
      }
    }
  }

  Future<void> _enqueueTomTomCompareFetch(Position location, double? headingDeg) async {
    if (_pipelinePaused) return;
    if (_tomtomCompareFetchInFlight) {
      _pendingTomTomCompareFetchLocation = location;
      return;
    }
    _tomtomCompareFetchInFlight = true;
    _pendingRelaxedFirstTomTomCompareFetch = false;
    _lastTomTomCompareFetchLocation = location;
    try {
      final snapMps = _effectiveSpeedMpsAndMph(location).$1;
      final out = await compare.fetchTomTomForCompare(
        latitude: location.latitude,
        longitude: location.longitude,
        headingDegrees: headingDeg,
        locationFixTimeUtcMs: location.timestamp.millisecondsSinceEpoch,
        speedMpsForSnapTiming: snapMps,
      );
      _tomtomCompareRouteModel = out.sectionModel;
    } finally {
      _tomtomCompareFetchInFlight = false;
      final next = _pendingTomTomCompareFetchLocation;
      _pendingTomTomCompareFetchLocation = null;
      if (next != null) {
        final nextRaw = _effectiveSpeedMpsAndMph(next).$2;
        final nextHeading =
            AndroidLocationCompat.positionBearingIfHasBearing(next);
        unawaited(_maybeRequestTomTomCompareFetch(next, nextRaw, nextHeading));
      }
    }
  }

  Future<void> _enqueueMapboxCompareFetch(Position location, double? headingDeg) async {
    if (_pipelinePaused) return;
    if (_mapboxCompareFetchInFlight) {
      _pendingMapboxCompareFetchLocation = location;
      return;
    }
    _mapboxCompareFetchInFlight = true;
    _pendingRelaxedFirstMapboxCompareFetch = false;
    _lastMapboxCompareFetchLocation = location;
    try {
      final out = await compare.fetchMapboxForCompare(
        latitude: location.latitude,
        longitude: location.longitude,
        headingDegrees: headingDeg,
      );
      _mapboxCompareRouteModel = out.sectionModel;
    } finally {
      _mapboxCompareFetchInFlight = false;
      final next = _pendingMapboxCompareFetchLocation;
      _pendingMapboxCompareFetchLocation = null;
      if (next != null) {
        final nextRaw = _effectiveSpeedMpsAndMph(next).$2;
        final nextHeading =
            AndroidLocationCompat.positionBearingIfHasBearing(next);
        unawaited(_maybeRequestMapboxCompareFetch(next, nextRaw, nextHeading));
      }
    }
  }

  void _invalidateHereGeometryForSharpTurn() {
    _hereSectionSpeedModel = null;
    _sectionWalkAlongContinuity.reset();
    _stickyRoadSegment = null;
    _lastApiFetchLocation = null;
    _speedLimitStabilizer.clear();
    _materialChangeGate.reset();
    _smallUpGate.reset();
    _moderateDownGate.reset();
    _lastRouteContextKey = null;
    _pendingRelaxedFirstFetch = true;
    _downwardLimitDebouncer.reset();
    _forceImmediateLimitCommit = true;
    _logHeadingInvalidateForDisplayTrace = true;
  }

  void _invalidateTomTomCompareForSharpTurn() {
    _tomtomCompareRouteModel = null;
    _lastTomTomCompareFetchLocation = null;
    _pendingRelaxedFirstTomTomCompareFetch = true;
    _tomtomCompareSustainedStartUtcMs = 0;
    _tomtomCompareFetchInFlight = false;
    _pendingTomTomCompareFetchLocation = null;
    compare.clearTomTomCompareStickyCacheOnly();
  }

  void _invalidateMapboxCompareForSharpTurn() {
    _mapboxCompareRouteModel = null;
    _lastMapboxCompareFetchLocation = null;
    _pendingRelaxedFirstMapboxCompareFetch = true;
    _mapboxCompareSustainedStartUtcMs = 0;
    _mapboxCompareFetchInFlight = false;
    _pendingMapboxCompareFetchLocation = null;
    compare.clearMapboxCompareStickyCacheOnly();
  }

  void _invalidateRouteGeometryForSharpTurn() {
    _invalidateHereGeometryForSharpTurn();
    _invalidateTomTomCompareForSharpTurn();
    _invalidateMapboxCompareForSharpTurn();
  }

  void _enqueueHereFetch(Position location, double displaySpeedMph) {
    if (_pipelinePaused) return;
    if (_hereFetchInFlight) {
      _pendingFetchLocation = location;
      _pendingFetchSpeedMph = displaySpeedMph;
      _emitSpeedUiOnly(displaySpeedMph, 'here_fetch_in_flight');
      return;
    }
    _hereFetchInFlight = true;
    _pendingRelaxedFirstFetch = false;
    final prevTriggerLoc = _lastApiFetchLocation;
    double? metersSincePrev;
    int? msSincePrev;
    if (prevTriggerLoc != null) {
      metersSincePrev = AndroidLocationCompat.distanceBetweenMeters(
        prevTriggerLoc.latitude,
        prevTriggerLoc.longitude,
        location.latitude,
        location.longitude,
      );
      final rawMs = location.timestamp.millisecondsSinceEpoch -
          prevTriggerLoc.timestamp.millisecondsSinceEpoch;
      msSincePrev = rawMs < 0 ? 0 : rawMs;
    }
    _lastApiFetchLocation = location;
    final generation = _speedFetchGeneration;
    unawaited(_runHereFetchChain(
      location,
      displaySpeedMph,
      generation,
      metersSincePrev,
      msSincePrev,
    ));
  }

  Future<void> _runHereFetchChain(
    Position location,
    double displaySpeedMph,
    int generation,
    double? metersSincePriorFetch,
    int? msSincePriorFetch,
  ) async {
    try {
      await _runShortHereFetch(
        location,
        displaySpeedMph,
        generation,
        metersSincePriorFetch,
        msSincePriorFetch,
      );
    } catch (e, st) {
      _stickyRoadSegment = null;
      _hereSectionSpeedModel = null;
      _sectionWalkAlongContinuity.reset();
      assert(() {
        // ignore: avoid_print
        print('LocationProcessor HERE fetch failed: $e\n$st');
        return true;
      }());
      if (generation == _speedFetchGeneration) {
        onSpeedUpdate(displaySpeedMph, _currentSpeedLimitMph);
      }
    } finally {
      _hereFetchInFlight = false;
      final next = _pendingFetchLocation;
      _pendingFetchLocation = null;
      _pendingFetchSpeedMph = null;
      if (next != null && generation == _speedFetchGeneration) {
        // Kotlin [enqueueHereFetch] finally: `(nextMps, nextRaw) = effectiveSpeedMpsAndMph(next)`;
        // `nextDisplay = nextRaw` — does **not** use [pendingFetchSpeedMph] for the chained call.
        final nextPair = _effectiveSpeedMpsAndMph(next);
        final nextMps = nextPair.$1;
        final nextRaw = nextPair.$2;
        final nextDisplay = nextRaw;
        if (useLocalHereForAlerts()) {
          _maybeRequestHereFetch(next, nextRaw, nextDisplay);
        } else if (_shouldFetchNewSpeedLimit(next, nextMps)) {
          _maybeRequestHereFetch(next, nextRaw, nextDisplay);
        }
      }
    }
  }

  Future<void> _runShortHereFetch(
    Position location,
    double vehicleSpeedMph,
    int generation,
    double? metersSincePriorFetch,
    int? msSincePriorFetch,
  ) async {
    final logCompare = preferencesManager.logSpeedFetchesToFile;
    final fetchStartedUtc = logCompare ? SpeedFetchDebugLogger.utcNow() : null;
    final logFields = logCompare
        ? _FetchCycleLogFields(
            vehicleSpeedMph: vehicleSpeedMph,
            metersSincePriorFetch: metersSincePriorFetch,
            msSincePriorFetch: msSincePriorFetch,
            generation: generation,
          )
        : null;

    final bearing = AndroidLocationCompat.positionBearingIfHasBearing(location);
    try {
      final t0Here = logCompare ? SpeedFetchDebugLogger.utcNow() : '';
      final hereResult = await speedLimitAggregator.fetchHereForAlerts(
        lat: location.latitude,
        lng: location.longitude,
        headingDegrees: bearing,
      );
      final t1Here = logCompare ? SpeedFetchDebugLogger.utcNow() : '';

      if (generation != _speedFetchGeneration) return;

      final resolvedHere = hereResult.data;
      final rawMph = resolvedHere.speedLimitMph;
      if (generation != _speedFetchGeneration) return;

      HereFetchTelemetry? telemetryObj;
      if (logCompare) {
        telemetryObj = _hereFetchTelemetryFrom(
          t0Here,
          t1Here,
          resolvedHere,
          hereResult.stickySegment,
          rawMph == null ? resolvedHere.source : null,
        );
      }

      if (rawMph != null) {
        _stickyRoadSegment = hereResult.stickySegment;
        _sectionWalkAlongContinuity.reset();
        _hereSectionSpeedModel = hereResult.sectionSpeedModel;
        _applyHereResolvedLimit(
          location: location,
          vehicleSpeedMph: vehicleSpeedMph,
          rawMph: rawMph,
          segmentKey: resolvedHere.segmentKey ?? hereResult.stickySegment?.linkId,
          functionalClass: resolvedHere.functionalClass,
          logCompareRow: logCompare,
          hereTelemetry: telemetryObj,
          logFields: logFields,
          hereLimitFromNetworkFetch: true,
          hereResolvePath: 'network',
        );
      } else {
        _stickyRoadSegment = null;
        _hereSectionSpeedModel = null;
        _sectionWalkAlongContinuity.reset();
        SpeedLimitLoggingContext.updateRoadFunctionalClass(resolvedHere.functionalClass);
        if (logCompare && telemetryObj != null && logFields != null) {
          final peek = _comparePeekMphForLogs();
          SpeedLimitLoggingContext.setHereAlertResolvePath('network_no_mph');
          await SpeedFetchDebugLogger.append(
            preferencesManager: preferencesManager,
            lat: location.latitude,
            lng: location.longitude,
            bearing: bearing,
            rawMph: -1,
            displayMph: -1,
            segmentKey: null,
            sourceTag: useLocalHereForAlerts() ? 'local_here' : 'remote_here',
            tomtomMph: peek.$1,
            mapboxMph: peek.$2,
            hereTelemetry: telemetryObj,
            vehicleSpeedMph: logFields.vehicleSpeedMph,
            metersSincePriorFetchTrigger: logFields.metersSincePriorFetch,
            msSincePriorFetchTrigger: logFields.msSincePriorFetch,
            fetchGeneration: logFields.generation,
            requestReasonHuman: _reasonHereFetchNoUsableMph,
          );
        }
        onSpeedUpdate(vehicleSpeedMph, _currentSpeedLimitMph);
      }
    } catch (e) {
      if (logCompare && fetchStartedUtc != null) {
        SpeedLimitLoggingContext.setHereAlertResolvePath('network_error');
        await SpeedFetchDebugLogger.appendHereApiFailure(
          preferencesManager: preferencesManager,
          lat: location.latitude,
          lng: location.longitude,
          bearing: bearing,
          sourceTag: useLocalHereForAlerts() ? 'local_here_error' : 'remote_here_error',
          requestReasonHuman: _reasonHereFetchException,
          hereTelemetry: HereFetchTelemetry(
            requestUtc: fetchStartedUtc,
            responseUtc: SpeedFetchDebugLogger.utcNow(),
            apiError: e.toString(),
          ),
          vehicleSpeedMph: logFields?.vehicleSpeedMph,
          metersSincePriorFetchTrigger: logFields?.metersSincePriorFetch,
          msSincePriorFetchTrigger: logFields?.msSincePriorFetch,
          fetchGeneration: logFields?.generation,
        );
      }
      rethrow;
    }
  }

  /// Kotlin [LocationProcessor.applyHereResolvedLimit] — **HERE-only** “brain” for the posted alert limit.
  ///
  /// Sequence (same as Kotlin):
  /// 1. Sanity / route context for raw HERE [rawMph] (caller already chose section-walk, sticky, or network).
  /// 2. Optional local [SpeedLimitStabilizer] + material / small-up / moderate-down gates.
  /// 3. [DownwardLimitDebouncer] commit → assign [_currentSpeedLimitMph].
  /// 4. [SpeedLimitLoggingContext.setHereCompareMphCell] + optional [SpeedFetchDebugLogger.append] with TomTom/Mapbox
  ///    peek columns (comparison mph only — same tick’s cache as Kotlin [peekCachedCompareTomTomMapboxMph]).
  /// 5. [onSpeedUpdate] — **sole** driver for alert UI / audio (Kotlin [checkSpeedAlert] in notifier).
  ///
  /// TomTom/Mapbox **never** enter this method; they run in [_enqueueCompareSideEffectsForLocationTick] / async queues.
  void _applyHereResolvedLimit({
    required Position location,
    required double vehicleSpeedMph,
    required int rawMph,
    required String? segmentKey,
    required int? functionalClass,
    bool logCompareRow = false,
    HereFetchTelemetry? hereTelemetry,
    _FetchCycleLogFields? logFields,
    bool hereLimitFromNetworkFetch = false,
    required String hereResolvePath,
  }) {
    SpeedLimitLoggingContext.setHereAlertResolvePath(hereResolvePath);
    SpeedLimitLoggingContext.updateRoadFunctionalClass(functionalClass);

    var rawForPipeline = rawMph;
    final curLimit = _currentSpeedLimitMph?.round();
    final sameLinkAsBefore =
        segmentKey != null && _lastHereSegmentKey != null && segmentKey == _lastHereSegmentKey;
    if (curLimit != null &&
        vehicleSpeedMph > 52 &&
        rawForPipeline < curLimit - SANITY_MAX_DROP_WHILE_FAST_MPH &&
        sameLinkAsBefore) {
      rawForPipeline = curLimit;
    }

    final routeCtx = _routeContextKey(functionalClass, segmentKey);

    var displayMph = rawForPipeline;
    if (shouldApplyLocalStabilizer()) {
      if (_lastRouteContextKey != null && routeCtx != _lastRouteContextKey) {
        _speedLimitStabilizer.clear();
        _materialChangeGate.reset();
        _smallUpGate.reset();
        _moderateDownGate.reset();
      }
      _lastRouteContextKey = routeCtx;

      if (segmentKey != null &&
          _lastHereSegmentKey != null &&
          segmentKey != _lastHereSegmentKey &&
          _lastHereRawMph != null &&
          rawForPipeline == _lastHereRawMph) {
        _speedLimitStabilizer.clear();
      }

      final smoothed = _speedLimitStabilizer.pushAndResolve(
        SpeedStabSample(segmentKey: segmentKey, mph: rawForPipeline),
      );
      final currentInt = _currentSpeedLimitMph?.round();
      if (currentInt == null) {
        _materialChangeGate.reset();
        _smallUpGate.reset();
        _moderateDownGate.reset();
        displayMph = smoothed;
      } else if ((rawForPipeline - currentInt).abs() >=
          SpeedLimitMaterialChangeGate.defaultMaterialDeltaMph) {
        _smallUpGate.reset();
        _moderateDownGate.reset();
        displayMph = _materialChangeGate.applyLargeRaw(rawForPipeline, _currentSpeedLimitMph);
      } else if (rawForPipeline > currentInt &&
          (rawForPipeline - currentInt) >= SpeedLimitSmallUpGate.defaultMinBump &&
          (rawForPipeline - currentInt) < SpeedLimitMaterialChangeGate.defaultMaterialDeltaMph) {
        _materialChangeGate.reset();
        _moderateDownGate.reset();
        displayMph = _smallUpGate.apply(rawForPipeline, _currentSpeedLimitMph, smoothed);
      } else if (rawForPipeline < currentInt) {
        final drop = currentInt - rawForPipeline;
        if (drop >= SpeedLimitModerateDownGate.defaultMinDrop &&
            drop < SpeedLimitMaterialChangeGate.defaultMaterialDeltaMph) {
          _materialChangeGate.reset();
          _smallUpGate.reset();
          displayMph = _moderateDownGate.apply(rawForPipeline, _currentSpeedLimitMph, smoothed);
        } else {
          _materialChangeGate.reset();
          _smallUpGate.reset();
          _moderateDownGate.reset();
          displayMph = smoothed;
        }
      } else {
        _materialChangeGate.reset();
        _smallUpGate.reset();
        _moderateDownGate.reset();
        displayMph = smoothed;
      }
    } else {
      _materialChangeGate.reset();
      _smallUpGate.reset();
      _moderateDownGate.reset();
      displayMph = rawForPipeline;
    }

    final segmentIdentityChanged =
        segmentKey != null && _lastHereSegmentKey != null && segmentKey != _lastHereSegmentKey;
    final immediateForDebounce = _forceImmediateLimitCommit || segmentIdentityChanged;
    _forceImmediateLimitCommit = false;
    final finalDisplay = _downwardLimitDebouncer.commit(
      displayMph,
      location.timestamp.millisecondsSinceEpoch,
      immediateForDebounce,
    );
    _currentSpeedLimitMph = finalDisplay.toDouble();
    SpeedLimitLoggingContext.setHereCompareMphCell(rawForPipeline, hereLimitFromNetworkFetch);
    if (logCompareRow && preferencesManager.logSpeedFetchesToFile) {
      final peek = _comparePeekMphForLogs();
      unawaited(
        SpeedFetchDebugLogger.append(
          preferencesManager: preferencesManager,
          lat: location.latitude,
          lng: location.longitude,
          bearing: AndroidLocationCompat.positionBearingIfHasBearing(location),
          rawMph: rawForPipeline,
          displayMph: finalDisplay,
          segmentKey: segmentKey,
          sourceTag: useLocalHereForAlerts() ? 'local_here' : 'remote_here',
          tomtomMph: peek.$1,
          mapboxMph: peek.$2,
          hereTelemetry: hereTelemetry,
          vehicleSpeedMph: logFields?.vehicleSpeedMph,
          metersSincePriorFetchTrigger: logFields?.metersSincePriorFetch,
          msSincePriorFetchTrigger: logFields?.msSincePriorFetch,
          fetchGeneration: logFields?.generation,
          requestReasonHuman: _reasonHereFetchSuccessRow,
        ),
      );
    }
    _logDisplayLimitChangeIfChanged(
      location: location,
      vehicleSpeedMph: vehicleSpeedMph,
      stabilizerMph: displayMph,
      finalDisplay: finalDisplay,
      segmentKey: segmentKey,
    );
    onSpeedUpdate(vehicleSpeedMph, _currentSpeedLimitMph);
    _lastHereSegmentKey = segmentKey;
    _lastHereRawMph = rawForPipeline;
  }

  void _logDisplayLimitChangeIfChanged({
    required Position location,
    required double vehicleSpeedMph,
    required int stabilizerMph,
    required int finalDisplay,
    String? segmentKey,
  }) {
    if (!preferencesManager.logSpeedFetchesToFile) return;
    final headingInv = _logHeadingInvalidateForDisplayTrace;
    _logHeadingInvalidateForDisplayTrace = false;
    final prev = _lastLoggedDisplayLimitMph;
    if (prev != null && finalDisplay == prev) return;
    _lastLoggedDisplayLimitMph = finalDisplay;
    unawaited(
      SpeedLimitApiRequestLogger.appendDisplayLimitChange(
        preferencesManager: preferencesManager,
        lat: location.latitude,
        lng: location.longitude,
        bearing: AndroidLocationCompat.positionBearingIfHasBearing(location),
        vehicleMph: vehicleSpeedMph,
        stabilizerMph: stabilizerMph,
        newDisplayMph: finalDisplay,
        previousDisplayMph: prev,
        segmentKey: segmentKey,
        sharpHeadingInvalidate: headingInv,
      ),
    );
  }

  static HereFetchTelemetry _hereFetchTelemetryFrom(
    String requestUtc,
    String responseUtc,
    SpeedLimitData data,
    RoadSegment? stickySegment,
    String? apiError,
  ) {
    return HereFetchTelemetry(
      requestUtc: requestUtc,
      responseUtc: responseUtc,
      responseSource: data.source,
      responseConfidence: data.confidence.name,
      functionalClass: data.functionalClass,
      segmentCacheZoneCount: stickySegment?.geometry.length,
      segmentCacheRouteLenM: stickySegment != null
          ? CrossTrackGeometry.polylineLengthMeters(stickySegment.geometry)
          : null,
      apiError: apiError,
    );
  }

  static const double SPEED_TRUST_MPS = 1.0;
  static const double MIN_DT_INFER_SEC = 0.15;
  static const double MAX_DT_INFER_SEC = 120.0;
  static const double MAX_INFERRED_MPS = 55.0;
  static const int SANITY_MAX_DROP_WHILE_FAST_MPH = 28;

  static const String _reasonHereFetchSuccessRow =
      'HERE fetch completed with a usable mph; row shows raw/display after stabilizer rules.';
  static const String _reasonHereFetchNoUsableMph =
      'HERE fetch completed but returned no usable mph; see here columns and note; prior limit kept if any.';
  static const String _reasonHereFetchException =
      'HERE alert fetch threw an exception before a complete response.';

  static const double DRIVING_MIN_MPH_FOR_FETCH = 9.0;
  static const int SUSTAINED_DRIVING_MS = 2500;
  static const int RELAXED_FIRST_FETCH_SUSTAINED_MS = 800;
  static const int RELAXED_FIRST_COMPARE_FETCH_SUSTAINED_MS = 0;

  static const double MIN_DISTANCE_CHANGE_METERS = 480.0;
  static const double MIN_HEADING_CHANGE_DEGREES = 45.0;
  static const double MIN_DISTANCE_CHANGE_METERS_REMOTE = 100.0;
  static const double MIN_HEADING_CHANGE_DEGREES_REMOTE = 22.0;
  static const double MIN_DISPLACEMENT_NOISE_METERS = 10.0;
  static const double STATIONARY_SPEED_MPS = 0.45;
  static const double STATIONARY_MAX_DISTANCE_FROM_LAST_FETCH_M = 20.0;
  static const double STATIONARY_DISPLAY_FREEZE_MPS = 2.24;

  static const double MIN_DISPLACEMENT_SINCE_FETCH_M = 100.0;
  static const double MIN_HEADING_CHANGE_FOR_FETCH_DEG = 45.0;

  static const double TOMTOM_NETWORK_MIN_DISPLACEMENT_M = 480.0;
  static const double TOMTOM_NETWORK_MIN_HEADING_CHANGE_DEG = 45.0;
  static const double TOMTOM_ALONG_POLYLINE_MAX_CROSS_TRACK_M = 72.0;
  static const double TOMTOM_ALONG_POLYLINE_PAST_END_BUFFER_M = 90.0;

  static const double MAPBOX_NETWORK_MIN_DISPLACEMENT_M = 480.0;
  static const double MAPBOX_NETWORK_MIN_HEADING_CHANGE_DEG = 45.0;
  static const double MAPBOX_ALONG_POLYLINE_MAX_CROSS_TRACK_M = 70.0;
  static const double MAPBOX_ALONG_POLYLINE_PAST_END_BUFFER_M = 88.0;

  static const double HEADING_UTURN_MIN_MPH = 12.0;
  static const double U_TURN_HEADING_DELTA_DEG = 125.0;
  static const double MODERATE_TURN_HEADING_DELTA_DEG = 45.0;
  static const int MODERATE_TURN_HEADING_COOLDOWN_MS = 4000;
}

class _FetchCycleLogFields {
  const _FetchCycleLogFields({
    required this.vehicleSpeedMph,
    this.metersSincePriorFetch,
    this.msSincePriorFetch,
    required this.generation,
  });

  final double vehicleSpeedMph;
  final double? metersSincePriorFetch;
  final int? msSincePriorFetch;
  final int generation;
}
