import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../config/app_config.dart';
import '../core/constants.dart' show SpeedLimitPrimaryProvider;
import '../core/speed_provider_constants.dart';
import '../core/android_location_compat.dart';
import '../engine/here/cross_track_geometry.dart';
import '../engine/mapbox/cross_track_geometry.dart';
import '../engine/tomtom/cross_track_geometry.dart';
import '../engine/shared/geo_bearing.dart';
import '../engine/shared/gps_trajectory_buffer.dart';
import '../logging/speed_fetch_debug_logger.dart';
import '../logging/speed_limit_api_request_logger.dart';
import '../engine/compare/compare_section_speed_model.dart';
import '../engine/here/section_speed_model.dart';
import '../engine/shared/section_walk_along_continuity.dart';
import '../engine/here/downward_limit_debouncer.dart';
import '../models/road_segment.dart';
import '../models/speed_limit_data.dart';
import '../logging/speed_limit_logging_context.dart';
import 'mapbox/speed_provider.dart';
import 'tomtom/speed_provider.dart';
import 'preferences_manager.dart';
import 'speed_limit_aggregator.dart';
import 'location_processing/here_primary_tick.dart';
import 'location_processing/remote_primary_tick.dart';
import 'location_processing/route_primary_tick_types.dart';

/// Driving-location pipeline: one **primary** speed provider ([PreferencesManager.resolvedPrimarySpeedLimitProvider])
/// drives alerts + main limit; other enabled providers run as **secondary** (same GPS/mock input).
///
/// **Thresholds** (private `static const` below): `RELAXED_FIRST_FETCH_SUSTAINED_MS` 800, `SUSTAINED_DRIVING_MS` 2500,
/// `RELAXED_FIRST_COMPARE_FETCH_SUSTAINED_MS` 0, `MIN_DISTANCE_CHANGE_METERS` 480,
/// `MIN_HEADING_CHANGE_DEGREES` 45, `MIN_DISTANCE_CHANGE_METERS_REMOTE` 100,
/// `MIN_HEADING_CHANGE_DEGREES_REMOTE` 22, `MIN_DISPLACEMENT_NOISE_METERS` 10,
/// `STATIONARY_SPEED_MPS` 0.45, `STATIONARY_MAX_DISTANCE_FROM_LAST_FETCH_M` 20,
/// `STATIONARY_DISPLAY_FREEZE_MPS` 2.24, `DRIVING_MIN_MPH_FOR_FETCH` 9,
/// `MIN_DISPLACEMENT_SINCE_FETCH_M` 100, `MIN_HEADING_CHANGE_FOR_FETCH_DEG` 45,
/// TomTom/Mapbox secondary gating: [SpeedProviderConstants] (tune each provider separately).
/// `HEADING_UTURN_MIN_MPH` 12, `U_TURN_HEADING_DELTA_DEG` 125,
/// `MODERATE_TURN_HEADING_DELTA_DEG` 45, `MODERATE_TURN_HEADING_COOLDOWN_MS` 4000.
///
/// **Primary HERE:** [HereSectionSpeedModel] + HERE Router fetch; **primary Remote:** separate route cache + Remote Edge fetch — each uses [_applyPrimaryResolvedLimit] with [HereDownwardLimitDebouncer].
///
/// **Primary TomTom or Mapbox:** [AnnotationSectionSpeedModel] from the corresponding [TomTomSpeedProvider] / [MapboxSpeedProvider] fetch; same section-walk projection, no downward debouncer.
///
/// **Secondary** providers: async fetches + along-polyline cache refresh only (no primary limit).
class LocationProcessor {
  LocationProcessor({
    required this.preferencesManager,
    required this.speedLimitAggregator,
    required this.tomTom,
    required this.mapbox,
    required this.onSpeedUpdate,
    this.onSecondaryVendorDataUpdated,
  });

  final PreferencesManager preferencesManager;
  final SpeedLimitAggregator speedLimitAggregator;
  final TomTomSpeedProvider tomTom;
  final MapboxSpeedProvider mapbox;

  /// Called after speed/limit updates so the owner can refresh UI, audio, and overlay in one place.
  final void Function(double vehicleSpeedMph, double? speedLimitMph) onSpeedUpdate;

  /// Called when secondary HERE or Remote compare mph updates (async; not every [onSpeedUpdate]).
  final void Function()? onSecondaryVendorDataUpdated;

  int get _primary => preferencesManager.resolvedPrimarySpeedLimitProvider;
  bool get _primaryHere => _primary == SpeedLimitPrimaryProvider.here;
  bool get _primaryRemote => _primary == SpeedLimitPrimaryProvider.remote;
  bool get _primaryTomTom => _primary == SpeedLimitPrimaryProvider.tomTom;
  bool get _primaryMapbox => _primary == SpeedLimitPrimaryProvider.mapbox;

  bool _pipelinePaused = false;

  Position? _lastApiFetchLocation;
  double? _currentSpeedLimitMph;
  int _speedFetchGeneration = 0;

  String? _lastHereSegmentKey;

  bool _logHeadingInvalidateForDisplayTrace = false;
  int? _lastLoggedDisplayLimitMph;

  RoadSegment? _hereStickyRoadSegment;
  HereSectionSpeedModel? _hereSectionSpeedModel;
  RoadSegment? _remoteStickyRoadSegment;
  HereSectionSpeedModel? _remoteSectionSpeedModel;

  final _sectionWalkAlongContinuity = SectionWalkAlongContinuity();

  AnnotationSectionSpeedModel? _tomtomRouteModel;
  AnnotationSectionSpeedModel? _mapboxRouteModel;

  final _hereDownwardLimitDebouncer = HereDownwardLimitDebouncer();

  double? _lastRouteHeadingDeg;
  int _lastModerateHeadingInvalidateUtcMs = 0;
  bool _forceImmediateLimitCommit = false;

  /// True while road-test simulation runs ([prepareForRoadTestSimulationStart] … [clearLimitCacheAfterSimulation]).
  bool _roadTestSimulationActive = false;

  Position? _lastProcessedLocation;

  final _gpsTrajectoryBuffer = GpsTrajectoryBuffer(capacity: 5);

  int _drivingSustainedStartUtcMs = 0;
  int _tomtomCompareSustainedStartUtcMs = 0;
  int _mapboxCompareSustainedStartUtcMs = 0;

  bool _pendingRelaxedFirstFetch = false;
  bool _pendingRelaxedFirstTomTomCompareFetch = true;
  bool _pendingRelaxedFirstMapboxCompareFetch = true;

  bool _primaryRouteFetchInFlight = false;
  Position? _pendingFetchLocation;
  // Stored while HERE fetch is in flight; chained retry recomputes speed from the pending fix.
  // ignore: unused_field
  double? _pendingFetchSpeedMph;

  bool _tomtomCompareFetchInFlight = false;
  Position? _pendingTomTomCompareFetchLocation;
  Position? _lastTomTomCompareFetchLocation;

  bool _mapboxCompareFetchInFlight = false;
  Position? _pendingMapboxCompareFetchLocation;
  Position? _lastMapboxCompareFetchLocation;

  /// Secondary HERE compare mph ([SpeedLimitAggregator.fetchHereMapsOnly]) when primary is not HERE.
  int? _hereCompareMph;
  int _hereCompareSustainedStartUtcMs = 0;
  bool _pendingRelaxedFirstHereCompareFetch = true;
  bool _hereCompareFetchInFlight = false;
  Position? _pendingHereCompareFetchLocation;
  Position? _lastHereCompareFetchLocation;

  /// Secondary Remote compare mph ([SpeedLimitAggregator.fetchRemoteMapsOnly]) when primary is not Remote.
  int? _remoteCompareMph;
  bool _remoteCompareFromCache = false;
  int _remoteCompareSustainedStartUtcMs = 0;
  bool _pendingRelaxedFirstRemoteCompareFetch = true;
  bool _remoteCompareFetchInFlight = false;
  Position? _pendingRemoteCompareFetchLocation;
  Position? _lastRemoteCompareFetchLocation;

  /// Whether the Remote primary speed limit was from cache (for UI indication).
  bool _remotePrimaryFromCache = false;

  /// HERE mph for secondary row when primary is not HERE (including Remote-primary: compare HERE vs Remote).
  int? get hereSecondaryCompareMph => _primaryHere ? null : _hereCompareMph;

  /// Remote mph for secondary row when primary is not Remote.
  int? get remoteSecondaryCompareMph => _primaryRemote ? null : _remoteCompareMph;

  /// Whether the Remote compare (secondary) mph was from cache.
  bool get remoteCompareFromCache => _remoteCompareFromCache;

  /// Whether the Remote primary mph was from cache.
  bool get remotePrimaryFromCache => _remotePrimaryFromCache;

  (int?, int?) _vendorPeekMphForLogs() {
    if (!preferencesManager.isTomTomApiEnabled &&
        !preferencesManager.isMapboxApiEnabled) {
      return (null, null);
    }
    return (tomTom.peekCached()?.speedLimitMph, mapbox.peekCached()?.speedLimitMph);
  }

  void setPipelinePaused(bool paused) {
    _pipelinePaused = paused;
    if (paused) {
      _speedFetchGeneration++;
      _lastProcessedLocation = null;
      _tomtomCompareSustainedStartUtcMs = 0;
      _mapboxCompareSustainedStartUtcMs = 0;
      _primaryRouteFetchInFlight = false;
      _pendingFetchLocation = null;
      _pendingFetchSpeedMph = null;
      _tomtomCompareFetchInFlight = false;
      _pendingTomTomCompareFetchLocation = null;
      _mapboxCompareFetchInFlight = false;
      _pendingMapboxCompareFetchLocation = null;
      _hereCompareFetchInFlight = false;
      _pendingHereCompareFetchLocation = null;
      _remoteCompareFetchInFlight = false;
      _pendingRemoteCompareFetchLocation = null;
      _tomtomRouteModel = null;
      _mapboxRouteModel = null;
    }
  }

  void markDrivingSessionStarted() {
    _pendingRelaxedFirstFetch = true;
    _pendingRelaxedFirstTomTomCompareFetch = true;
    _pendingRelaxedFirstMapboxCompareFetch = true;
    _pendingRelaxedFirstHereCompareFetch = true;
    _pendingRelaxedFirstRemoteCompareFetch = true;
    _lastProcessedLocation = null;
  }

  void prepareForRoadTestSimulationStart() {
    _resetSessionState(
      relaxedFirstFetch: true,
      resetDrivingLogSession: false,
    );
    _roadTestSimulationActive = true;
  }

  /// After [prepareForRoadTestSimulationStart], seed HERE primary section-walk from the device Router O–D response.
  void primeHereSectionSpeedModelFromSimulationOdRoute(HereSectionSpeedModel? model) {
    if (model == null) return;
    _hereSectionSpeedModel = model;
    _sectionWalkAlongContinuity.reset();
  }

  /// Same as [primeHereSectionSpeedModelFromSimulationOdRoute] for routes resolved via Remote Edge.
  void primeRemoteSectionSpeedModelFromSimulationOdRoute(HereSectionSpeedModel? model) {
    if (model == null) return;
    _remoteSectionSpeedModel = model;
    _sectionWalkAlongContinuity.reset();
  }

  void clearLimitCacheAfterSimulation() {
    _resetSessionState(
      relaxedFirstFetch: false,
      resetDrivingLogSession: true,
    );
    _roadTestSimulationActive = false;
  }

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
    _lastHereCompareFetchLocation = null;
    _lastRemoteCompareFetchLocation = null;
    _pendingRelaxedFirstTomTomCompareFetch = true;
    _pendingRelaxedFirstMapboxCompareFetch = true;
    _pendingRelaxedFirstHereCompareFetch = true;
    _pendingRelaxedFirstRemoteCompareFetch = true;
    _hereCompareSustainedStartUtcMs = 0;
    _remoteCompareSustainedStartUtcMs = 0;
    _currentSpeedLimitMph = null;
    _hereStickyRoadSegment = null;
    _hereSectionSpeedModel = null;
    _remoteStickyRoadSegment = null;
    _remoteSectionSpeedModel = null;
    _sectionWalkAlongContinuity.reset();
    _tomtomRouteModel = null;
    _mapboxRouteModel = null;
    _hereDownwardLimitDebouncer.reset();
    _lastRouteHeadingDeg = null;
    _lastModerateHeadingInvalidateUtcMs = 0;
    _forceImmediateLimitCommit = false;
    _primaryRouteFetchInFlight = false;
    _pendingFetchLocation = null;
    _pendingFetchSpeedMph = null;
    _tomtomCompareFetchInFlight = false;
    _pendingTomTomCompareFetchLocation = null;
    _mapboxCompareFetchInFlight = false;
    _pendingMapboxCompareFetchLocation = null;
    _hereCompareFetchInFlight = false;
    _pendingHereCompareFetchLocation = null;
    _hereCompareMph = null;
    _remoteCompareFetchInFlight = false;
    _pendingRemoteCompareFetchLocation = null;
    _remoteCompareMph = null;
    tomTom.clearStickyCacheOnly();
    mapbox.clearStickyCacheOnly();
    _lastHereSegmentKey = null;
    _gpsTrajectoryBuffer.clear();
    _logHeadingInvalidateForDisplayTrace = false;
    _lastLoggedDisplayLimitMph = null;
  }

  /// Entry point for each new GPS fix (respects pipeline pause).
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

  /// Wraps [processNewLocationInnerBody] and records [_lastProcessedLocation].
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

  /// Secondary HERE / TomTom / Mapbox network fetches + along-polyline cache refresh. Primary fetch runs in the main tail.
  void _enqueueCompareSideEffectsForLocationTick(
    Position location,
    double rawMph,
    double? headingForPolyline,
    HerePolylineMatchingOptions hereMatchOpts,
    TomTomPolylineMatchingOptions tomTomMatchOpts,
    MapboxPolylineMatchingOptions mapboxMatchOpts,
  ) {
    if (!_primaryHere) {
      unawaited(
        _maybeRequestHereCompareFetch(location, rawMph, headingForPolyline),
      );
    }
    if (!_primaryRemote &&
        AppConfig.useRemoteHere &&
        preferencesManager.isRemoteApiEnabled) {
      unawaited(
        _maybeRequestRemoteCompareFetch(location, rawMph, headingForPolyline),
      );
    }
    if (!_primaryTomTom) {
      unawaited(
        _maybeRequestTomTomCompareFetch(location, rawMph, headingForPolyline),
      );
    }
    if (!_primaryMapbox) {
      unawaited(
        _maybeRequestMapboxCompareFetch(location, rawMph, headingForPolyline),
      );
    }
    _applyRouteModelsAlongPolyline(
      location,
      headingForPolyline,
      tomTomMatchOpts,
      mapboxMatchOpts,
    );
  }

  /// Per-fix pipeline: speed → sustained anchors → trajectory → logging → heading → vendor side effects.
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
    _updateHereCompareSustainedAnchor(location, rawMph);
    _updateRemoteCompareSustainedAnchor(location, rawMph);

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
    final hereMatchOpts = HerePolylineMatchingOptions.fromPosition(location);
    final tomTomMatchOpts = TomTomPolylineMatchingOptions.fromPosition(location);
    final mapboxMatchOpts = MapboxPolylineMatchingOptions.fromPosition(location);

    _maybeInvalidateForSharpHeadingChange(userHeading, rawMph, location.timestamp.millisecondsSinceEpoch);
    // Sharp-turn invalidation clears TomTom/Mapbox sustained anchors. Re-arm immediately so
    // gates see the current fix as sustained driving in the same tick (otherwise secondary fetches often never
    // ran during simulation when bearing jumped each route vertex).
    _updateTomTomCompareSustainedAnchor(location, rawMph);
    _updateMapboxCompareSustainedAnchor(location, rawMph);
    _updateHereCompareSustainedAnchor(location, rawMph);
    _updateRemoteCompareSustainedAnchor(location, rawMph);
    _enqueueCompareSideEffectsForLocationTick(
      location,
      rawMph,
      headingForPolyline,
      hereMatchOpts,
      tomTomMatchOpts,
      mapboxMatchOpts,
    );

    if (_primaryHere) {
      final sw = herePrimaryTrySectionWalk(
        location: location,
        hereMatchOpts: hereMatchOpts,
        headingForPolyline: headingForPolyline,
        routeModel: _hereSectionSpeedModel,
        continuity: _sectionWalkAlongContinuity,
      );
      if (sw is RoutePrimarySectionWalkStop) {
        final a = sw.apply;
        _applyPrimaryResolvedLimit(
          location: location,
          vehicleSpeedMph: displayMph,
          rawMph: a.rawMph,
          segmentKey: a.segmentKey,
          functionalClass: a.functionalClass,
          logCompareRow: false,
          fetchTelemetry: null,
          logFields: null,
          hereLimitFromNetworkFetch: false,
          hereResolvePath: a.resolvePath,
        );
        return;
      }
      if (sw is RoutePrimarySectionWalkInvalidate) {
        _sectionWalkAlongContinuity.reset();
        _hereSectionSpeedModel = null;
      }
    }

    if (_primaryRemote) {
      final sw = remotePrimaryTrySectionWalk(
        location: location,
        hereMatchOpts: hereMatchOpts,
        headingForPolyline: headingForPolyline,
        routeModel: _remoteSectionSpeedModel,
        continuity: _sectionWalkAlongContinuity,
      );
      if (sw is RoutePrimarySectionWalkStop) {
        final a = sw.apply;
        _applyPrimaryResolvedLimit(
          location: location,
          vehicleSpeedMph: displayMph,
          rawMph: a.rawMph,
          segmentKey: a.segmentKey,
          functionalClass: a.functionalClass,
          logCompareRow: false,
          fetchTelemetry: null,
          logFields: null,
          hereLimitFromNetworkFetch: false,
          hereResolvePath: a.resolvePath,
        );
        return;
      }
      if (sw is RoutePrimarySectionWalkInvalidate) {
        _sectionWalkAlongContinuity.reset();
        _remoteSectionSpeedModel = null;
      }
    }

    if (_primaryTomTom) {
      final routeModel = _tomtomRouteModel;
      if (routeModel != null && !routeModel.isExpired()) {
        final tomTomOpts =
            tomTomMatchOpts.withEdgeMph(routeModel.mphHintsPerEdge());
        final proj = TomTomCrossTrackGeometry.projectOntoPolylineForMatching(
          location.latitude,
          location.longitude,
          routeModel.geometry,
          headingForPolyline,
          matchingOptions: tomTomOpts,
        );
        if (proj != null &&
            TomTomCrossTrackGeometry.isSectionWalkProjectionValid(
              proj,
              routeModel.geometry,
              headingForPolyline,
              matchingOptions: tomTomOpts,
            )) {
          final alongRaw = proj.alongMeters;
          final along = _sectionWalkAlongContinuity.clampAlong(alongRaw, location);
          final resolved = routeModel.speedLimitDataAtAlong(along);
          final mph = resolved.speedLimitMph;
          if (mph != null) {
            _applyPrimaryResolvedLimit(
              location: location,
              vehicleSpeedMph: displayMph,
              rawMph: mph,
              segmentKey: resolved.segmentKey,
              functionalClass: resolved.functionalClass,
              logCompareRow: false,
              fetchTelemetry: null,
              logFields: null,
              hereLimitFromNetworkFetch: false,
              hereResolvePath: 'section_walk',
            );
            return;
          }
        } else {
          _sectionWalkAlongContinuity.reset();
          _tomtomRouteModel = null;
        }
      }
    }

    if (_primaryMapbox) {
      final routeModel = _mapboxRouteModel;
      if (routeModel != null && !routeModel.isExpired()) {
        final mapboxOpts =
            mapboxMatchOpts.withEdgeMph(routeModel.mphHintsPerEdge());
        final proj = MapboxCrossTrackGeometry.projectOntoPolylineForMatching(
          location.latitude,
          location.longitude,
          routeModel.geometry,
          headingForPolyline,
          matchingOptions: mapboxOpts,
        );
        if (proj != null &&
            MapboxCrossTrackGeometry.isSectionWalkProjectionValid(
              proj,
              routeModel.geometry,
              headingForPolyline,
              matchingOptions: mapboxOpts,
            )) {
          final alongRaw = proj.alongMeters;
          final along = _sectionWalkAlongContinuity.clampAlong(alongRaw, location);
          final resolved = routeModel.speedLimitDataAtAlong(along);
          final mph = resolved.speedLimitMph;
          if (mph != null) {
            _applyPrimaryResolvedLimit(
              location: location,
              vehicleSpeedMph: displayMph,
              rawMph: mph,
              segmentKey: resolved.segmentKey,
              functionalClass: resolved.functionalClass,
              logCompareRow: false,
              fetchTelemetry: null,
              logFields: null,
              hereLimitFromNetworkFetch: false,
              hereResolvePath: 'section_walk',
            );
            return;
          }
        } else {
          _sectionWalkAlongContinuity.reset();
          _mapboxRouteModel = null;
        }
      }
    }

    if (_primaryHere) {
      final snap = herePrimaryTrySticky(
        location: location,
        headingForPolyline: headingForPolyline,
        sticky: _hereStickyRoadSegment,
      );
      if (snap != null) {
        _applyPrimaryResolvedLimit(
          location: location,
          vehicleSpeedMph: displayMph,
          rawMph: snap.rawMph,
          segmentKey: snap.segmentKey,
          functionalClass: snap.functionalClass,
          logCompareRow: false,
          fetchTelemetry: null,
          logFields: null,
          hereLimitFromNetworkFetch: false,
          hereResolvePath: snap.resolvePath,
        );
        return;
      }
    }

    if (_primaryRemote) {
      final snap = remotePrimaryTrySticky(
        location: location,
        headingForPolyline: headingForPolyline,
        sticky: _remoteStickyRoadSegment,
      );
      if (snap != null) {
        _applyPrimaryResolvedLimit(
          location: location,
          vehicleSpeedMph: displayMph,
          rawMph: snap.rawMph,
          segmentKey: snap.segmentKey,
          functionalClass: snap.functionalClass,
          logCompareRow: false,
          fetchTelemetry: null,
          logFields: null,
          hereLimitFromNetworkFetch: false,
          hereResolvePath: snap.resolvePath,
        );
        return;
      }
    }

    final hasPrimaryGeometry = (_primaryHere &&
            (_hereStickyRoadSegment != null || _hereSectionSpeedModel != null)) ||
        (_primaryRemote &&
            (_remoteStickyRoadSegment != null || _remoteSectionSpeedModel != null)) ||
        (_primaryTomTom && _tomtomRouteModel != null) ||
        (_primaryMapbox && _mapboxRouteModel != null);
    if (speedMps < STATIONARY_DISPLAY_FREEZE_MPS &&
        AndroidLocationCompat.positionHasReportedSpeed(location) &&
        hasPrimaryGeometry) {
      final lim = _currentSpeedLimitMph ??
          (_primaryHere ? _hereStickyRoadSegment?.speedLimitMph : null) ??
          (_primaryRemote ? _remoteStickyRoadSegment?.speedLimitMph : null);
      if (lim == null) return;
      SpeedLimitLoggingContext.setHereAlertResolvePath('stationary_hold');
      onSpeedUpdate(displayMph, lim);
      return;
    }

    if (_primaryHere) {
      if (!preferencesManager.isHereApiEnabled) {
        _emitSpeedUiOnly(displayMph, 'here_fetch_disabled');
        return;
      }
      _maybeRequestHereFetch(location, rawMph, displayMph);
      return;
    }

    if (_primaryRemote) {
      if (!AppConfig.useRemoteHere || !preferencesManager.isRemoteApiEnabled) {
        _emitSpeedUiOnly(displayMph, 'remote_fetch_disabled');
        return;
      }
      if (_shouldFetchNewSpeedLimit(location, speedMps)) {
        if (_shouldTriggerHereSpeedLimitFetch(location, rawMph)) {
          _maybeRequestRemoteFetch(location, rawMph, displayMph);
        } else {
          _emitSpeedUiOnly(displayMph, 'remote_fetch_gated');
        }
      } else {
        SpeedLimitLoggingContext.setHereAlertResolvePath('remote_cache_idle');
        onSpeedUpdate(displayMph, _currentSpeedLimitMph);
      }
      return;
    }

    if (_primaryTomTom) {
      if (preferencesManager.isTomTomApiEnabled) {
        if (_shouldFetchNewSpeedLimit(location, speedMps)) {
          if (_shouldTriggerHereSpeedLimitFetch(location, rawMph)) {
            _maybeRequestTomTomPrimaryFetch(location, rawMph, displayMph);
          } else {
            _emitSpeedUiOnly(displayMph, 'tomtom_fetch_gated');
          }
        } else {
          _emitSpeedUiOnly(displayMph, 'tomtom_fetch_idle');
        }
      } else {
        _emitSpeedUiOnly(displayMph, 'tomtom_fetch_disabled');
      }
      return;
    }

    if (_primaryMapbox) {
      if (preferencesManager.isMapboxApiEnabled) {
        if (_shouldFetchNewSpeedLimit(location, speedMps)) {
          if (_shouldTriggerHereSpeedLimitFetch(location, rawMph)) {
            _maybeRequestMapboxPrimaryFetch(location, rawMph, displayMph);
          } else {
            _emitSpeedUiOnly(displayMph, 'mapbox_fetch_gated');
          }
        } else {
          _emitSpeedUiOnly(displayMph, 'mapbox_fetch_idle');
        }
      } else {
        _emitSpeedUiOnly(displayMph, 'mapbox_fetch_disabled');
      }
      return;
    }

    _emitSpeedUiOnly(displayMph, 'primary_provider_unresolved');
  }

  (double, double) _speedMpsAndRawMph(Position location) {
    if (AndroidLocationCompat.positionHasReportedSpeed(location) &&
        location.speed >= 0) {
      final mps = location.speed;
      return (mps, mps * 2.23694);
    }
    return (0.0, 0.0);
  }

  // Device speed when trusted; else infer from displacement / Δt with clamps.
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

  void _updateHereCompareSustainedAnchor(Position location, double rawMph) {
    if (_primaryHere || !preferencesManager.isHereApiEnabled) {
      _hereCompareSustainedStartUtcMs = 0;
      return;
    }
    if (rawMph >= DRIVING_MIN_MPH_FOR_FETCH) {
      if (_hereCompareSustainedStartUtcMs == 0) {
        _hereCompareSustainedStartUtcMs = location.timestamp.millisecondsSinceEpoch;
      }
    } else {
      _hereCompareSustainedStartUtcMs = 0;
    }
  }

  void _updateRemoteCompareSustainedAnchor(Position location, double rawMph) {
    if (_primaryRemote ||
        !AppConfig.useRemoteHere ||
        !preferencesManager.isRemoteApiEnabled) {
      _remoteCompareSustainedStartUtcMs = 0;
      return;
    }
    if (rawMph >= DRIVING_MIN_MPH_FOR_FETCH) {
      if (_remoteCompareSustainedStartUtcMs == 0) {
        _remoteCompareSustainedStartUtcMs =
            location.timestamp.millisecondsSinceEpoch;
      }
    } else {
      _remoteCompareSustainedStartUtcMs = 0;
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
    _enqueueHerePrimaryFetch(location, displayMph);
  }

  void _maybeRequestRemoteFetch(Position location, double rawMph, double displayMph) {
    if (!_shouldTriggerHereSpeedLimitFetch(location, rawMph)) {
      _emitSpeedUiOnly(displayMph, 'remote_fetch_gated');
      return;
    }
    _enqueueRemotePrimaryFetch(location, displayMph);
  }

  /// Local distance/heading thresholds for primary fetch (HERE primary; Remote uses wider “remote” thresholds).
  bool _useLocalDistanceThresholdsForPrimaryFetch() =>
      _primaryHere || _primaryTomTom || _primaryMapbox;

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

    final minDist = _useLocalDistanceThresholdsForPrimaryFetch()
        ? MIN_DISTANCE_CHANGE_METERS
        : MIN_DISTANCE_CHANGE_METERS_REMOTE;
    final minHeading = _useLocalDistanceThresholdsForPrimaryFetch()
        ? MIN_HEADING_CHANGE_DEGREES
        : MIN_HEADING_CHANGE_DEGREES_REMOTE;
    return distance >= minDist || headingChange >= minHeading;
  }

  void _maybeInvalidateForSharpHeadingChange(
    double? userHeading,
    double rawMph,
    int locationTimeUtcMs,
  ) {
    if (_roadTestSimulationActive) return;
    if (rawMph < HEADING_UTURN_MIN_MPH) return;
    if (userHeading == null || !userHeading.isFinite) return;
    final prev = _lastRouteHeadingDeg;
    if (prev != null && prev.isFinite) {
      final delta = smallestBearingDeltaDeg(userHeading, prev);
      if (delta >= U_TURN_HEADING_DELTA_DEG) {
        _invalidateRouteGeometryForSharpTurn();
        _lastModerateHeadingInvalidateUtcMs = locationTimeUtcMs;
      } else if (delta >= MODERATE_TURN_HEADING_DELTA_DEG) {
        // Elapsed ms since last moderate invalidate, floored at 0.
        final sinceLastModerate = _lastModerateHeadingInvalidateUtcMs == 0
            ? AndroidLocationCompat.javaLongMaxValue
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

  bool _hereCompareSustainedEligible(Position location, double rawMph) {
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (_hereCompareSustainedStartUtcMs == 0) return false;
    final requiredMs = _pendingRelaxedFirstHereCompareFetch
        ? RELAXED_FIRST_COMPARE_FETCH_SUSTAINED_MS
        : SUSTAINED_DRIVING_MS;
    return (location.timestamp.millisecondsSinceEpoch - _hereCompareSustainedStartUtcMs) >=
        requiredMs;
  }

  bool _tomtomCompareHasUsableRouteCache() {
    final m = _tomtomRouteModel;
    return m != null && !m.isExpired();
  }

  bool _mapboxCompareHasUsableRouteCache() {
    final m = _mapboxRouteModel;
    return m != null && !m.isExpired();
  }

  bool _shouldTriggerTomTomCompareFetch(Position location, double rawMph) {
    if (!preferencesManager.isTomTomApiEnabled) return false;
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (!_tomtomCompareSustainedEligible(location, rawMph)) return false;
    final minDisp = _tomtomCompareHasUsableRouteCache()
        ? SpeedProviderConstants.tomtomSecondaryNetworkMinDisplacementM
        : MIN_DISPLACEMENT_SINCE_FETCH_M;
    return _sufficientDisplacementSinceLastForNetworkFetch(
      location,
      _lastTomTomCompareFetchLocation,
      minDisp,
      SpeedProviderConstants.tomtomSecondaryNetworkMinHeadingChangeDeg,
    );
  }

  bool _shouldTriggerMapboxCompareFetch(Position location, double rawMph) {
    if (!preferencesManager.isMapboxApiEnabled) return false;
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (!_mapboxCompareSustainedEligible(location, rawMph)) return false;
    final minDisp = _mapboxCompareHasUsableRouteCache()
        ? SpeedProviderConstants.mapboxSecondaryNetworkMinDisplacementM
        : MIN_DISPLACEMENT_SINCE_FETCH_M;
    return _sufficientDisplacementSinceLastForNetworkFetch(
      location,
      _lastMapboxCompareFetchLocation,
      minDisp,
      SpeedProviderConstants.mapboxSecondaryNetworkMinHeadingChangeDeg,
    );
  }

  bool _shouldTriggerHereCompareFetch(Position location, double rawMph) {
    if (_primaryHere || !preferencesManager.isHereApiEnabled) {
      return false;
    }
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (!_hereCompareSustainedEligible(location, rawMph)) return false;
    return _sufficientDisplacementSinceLastForNetworkFetch(
      location,
      _lastHereCompareFetchLocation,
      MIN_DISPLACEMENT_SINCE_FETCH_M,
      MIN_HEADING_CHANGE_FOR_FETCH_DEG,
    );
  }

  bool _remoteCompareSustainedEligible(Position location, double rawMph) {
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (_remoteCompareSustainedStartUtcMs == 0) return false;
    final requiredMs = _pendingRelaxedFirstRemoteCompareFetch
        ? RELAXED_FIRST_COMPARE_FETCH_SUSTAINED_MS
        : SUSTAINED_DRIVING_MS;
    return (location.timestamp.millisecondsSinceEpoch - _remoteCompareSustainedStartUtcMs) >=
        requiredMs;
  }

  bool _shouldTriggerRemoteCompareFetch(Position location, double rawMph) {
    if (_primaryRemote ||
        !AppConfig.useRemoteHere ||
        !preferencesManager.isRemoteApiEnabled) {
      return false;
    }
    if (rawMph < DRIVING_MIN_MPH_FOR_FETCH) return false;
    if (!_remoteCompareSustainedEligible(location, rawMph)) return false;
    return _sufficientDisplacementSinceLastForNetworkFetch(
      location,
      _lastRemoteCompareFetchLocation,
      MIN_DISPLACEMENT_SINCE_FETCH_M,
      MIN_HEADING_CHANGE_FOR_FETCH_DEG,
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

  Future<void> _maybeRequestHereCompareFetch(
    Position location,
    double rawMph,
    double? headingDeg,
  ) async {
    if (!_shouldTriggerHereCompareFetch(location, rawMph)) return;
    await _enqueueHereCompareFetch(location, headingDeg);
  }

  Future<void> _maybeRequestRemoteCompareFetch(
    Position location,
    double rawMph,
    double? headingDeg,
  ) async {
    if (!_shouldTriggerRemoteCompareFetch(location, rawMph)) return;
    await _enqueueRemoteCompareFetch(location, headingDeg);
  }

  Future<void> _enqueueHereCompareFetch(Position location, double? headingDeg) async {
    if (_pipelinePaused) return;
    if (_hereCompareFetchInFlight) {
      _pendingHereCompareFetchLocation = location;
      return;
    }
    _hereCompareFetchInFlight = true;
    _pendingRelaxedFirstHereCompareFetch = false;
    _lastHereCompareFetchLocation = location;
    final generation = _speedFetchGeneration;
    try {
      final data = await speedLimitAggregator.fetchHereMapsOnly(
        lat: location.latitude,
        lng: location.longitude,
        headingDegrees: headingDeg,
      );
      if (generation != _speedFetchGeneration) return;
      if (_primaryHere) return;
      _hereCompareMph = data.speedLimitMph;
      SpeedLimitLoggingContext.setHereMphCell(data.speedLimitMph, true);
      onSecondaryVendorDataUpdated?.call();
    } catch (_) {
      // Keep previous _hereCompareMph.
    } finally {
      _hereCompareFetchInFlight = false;
      final next = _pendingHereCompareFetchLocation;
      _pendingHereCompareFetchLocation = null;
      if (next != null && generation == _speedFetchGeneration) {
        final nextRaw = _effectiveSpeedMpsAndMph(next).$2;
        final nextHeading =
            AndroidLocationCompat.positionBearingIfHasBearing(next);
        unawaited(_maybeRequestHereCompareFetch(next, nextRaw, nextHeading));
      }
    }
  }

  Future<void> _enqueueRemoteCompareFetch(Position location, double? headingDeg) async {
    if (_pipelinePaused) return;
    if (_remoteCompareFetchInFlight) {
      _pendingRemoteCompareFetchLocation = location;
      return;
    }
    _remoteCompareFetchInFlight = true;
    _pendingRelaxedFirstRemoteCompareFetch = false;
    _lastRemoteCompareFetchLocation = location;
    final generation = _speedFetchGeneration;
    try {
      final data = await speedLimitAggregator.fetchRemoteMapsOnly(
        lat: location.latitude,
        lng: location.longitude,
        headingDegrees: headingDeg,
      );
      if (generation != _speedFetchGeneration) return;
      if (_primaryRemote) return;
      _remoteCompareMph = data.speedLimitMph;
      _remoteCompareFromCache = data.source.contains('(cached)');
      SpeedLimitLoggingContext.setRemoteMphCell(data.speedLimitMph, true);
      onSecondaryVendorDataUpdated?.call();
    } catch (_) {
      // Keep previous _remoteCompareMph.
    } finally {
      _remoteCompareFetchInFlight = false;
      final next = _pendingRemoteCompareFetchLocation;
      _pendingRemoteCompareFetchLocation = null;
      if (next != null && generation == _speedFetchGeneration) {
        final nextRaw = _effectiveSpeedMpsAndMph(next).$2;
        final nextHeading =
            AndroidLocationCompat.positionBearingIfHasBearing(next);
        unawaited(_maybeRequestRemoteCompareFetch(next, nextRaw, nextHeading));
      }
    }
  }

  void _applyRouteModelsAlongPolyline(
    Position location,
    double? headingForPolyline,
    TomTomPolylineMatchingOptions tomTomBase,
    MapboxPolylineMatchingOptions mapboxBase,
  ) {
    final tm = _tomtomRouteModel;
    if (tm != null && !tm.isExpired()) {
      final tomTomOpts = tomTomBase.withEdgeMph(tm.mphHintsPerEdge());
      if (TomTomCrossTrackGeometry.isUserOnPolylineForAlongResolve(
        location.latitude,
        location.longitude,
        tm.geometry,
        maxCrossTrackM: SpeedProviderConstants.tomtomSecondaryAlongMaxCrossTrackM,
        pastEndBufferM: SpeedProviderConstants.tomtomSecondaryAlongPastEndBufferM,
        userHeadingDeg: headingForPolyline,
        matchingOptions: tomTomOpts,
      )) {
        final along = TomTomCrossTrackGeometry.alongPolylineMetersForMatching(
          location.latitude,
          location.longitude,
          tm.geometry,
          headingForPolyline,
          matchingOptions: tomTomOpts,
        );
        tomTom.publishFromAlong(tm.speedLimitDataAtAlong(along));
      } else {
        _tomtomRouteModel = null;
      }
    }
    final mb = _mapboxRouteModel;
    if (mb != null && !mb.isExpired()) {
      final mapboxOpts = mapboxBase.withEdgeMph(mb.mphHintsPerEdge());
      if (MapboxCrossTrackGeometry.isUserOnPolylineForAlongResolve(
        location.latitude,
        location.longitude,
        mb.geometry,
        maxCrossTrackM: SpeedProviderConstants.mapboxSecondaryAlongMaxCrossTrackM,
        pastEndBufferM: SpeedProviderConstants.mapboxSecondaryAlongPastEndBufferM,
        userHeadingDeg: headingForPolyline,
        matchingOptions: mapboxOpts,
      )) {
        final along = MapboxCrossTrackGeometry.alongPolylineMetersForMatching(
          location.latitude,
          location.longitude,
          mb.geometry,
          headingForPolyline,
          matchingOptions: mapboxOpts,
        );
        mapbox.publishFromAlong(mb.speedLimitDataAtAlong(along));
      } else {
        _mapboxRouteModel = null;
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
      final out = await tomTom.fetchSpeedLimit(
        latitude: location.latitude,
        longitude: location.longitude,
        headingDegrees: headingDeg,
        locationFixTimeUtcMs: location.timestamp.millisecondsSinceEpoch,
        speedMpsForSnapTiming: snapMps,
        polylineMatchingOptions: TomTomPolylineMatchingOptions.fromPosition(location),
      );
      _tomtomRouteModel = out.sectionModel;
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
      final out = await mapbox.fetchSpeedLimit(
        latitude: location.latitude,
        longitude: location.longitude,
        headingDegrees: headingDeg,
        polylineMatchingOptions: MapboxPolylineMatchingOptions.fromPosition(location),
      );
      _mapboxRouteModel = out.sectionModel;
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

  /// Clears HERE and Remote primary route caches (sharp turn / U-turn).
  void _invalidatePrimaryRouteGeometryForSharpTurn() {
    _hereSectionSpeedModel = null;
    _remoteSectionSpeedModel = null;
    _sectionWalkAlongContinuity.reset();
    _hereStickyRoadSegment = null;
    _remoteStickyRoadSegment = null;
    _lastApiFetchLocation = null;
    _pendingRelaxedFirstFetch = true;
    _hereDownwardLimitDebouncer.reset();
    _forceImmediateLimitCommit = true;
    _logHeadingInvalidateForDisplayTrace = true;
  }

  void _invalidateTomTomCompareForSharpTurn() {
    _tomtomRouteModel = null;
    _lastTomTomCompareFetchLocation = null;
    _pendingRelaxedFirstTomTomCompareFetch = true;
    _tomtomCompareSustainedStartUtcMs = 0;
    _tomtomCompareFetchInFlight = false;
    _pendingTomTomCompareFetchLocation = null;
    tomTom.clearStickyCacheOnly();
  }

  void _invalidateMapboxCompareForSharpTurn() {
    _mapboxRouteModel = null;
    _lastMapboxCompareFetchLocation = null;
    _pendingRelaxedFirstMapboxCompareFetch = true;
    _mapboxCompareSustainedStartUtcMs = 0;
    _mapboxCompareFetchInFlight = false;
    _pendingMapboxCompareFetchLocation = null;
    mapbox.clearStickyCacheOnly();
  }

  void _invalidateHereCompareForSharpTurn() {
    _lastHereCompareFetchLocation = null;
    _pendingRelaxedFirstHereCompareFetch = true;
    _hereCompareSustainedStartUtcMs = 0;
    _hereCompareFetchInFlight = false;
    _pendingHereCompareFetchLocation = null;
    _hereCompareMph = null;
    if (!_primaryHere) {
      SpeedLimitLoggingContext.setHereMphCell(null, false);
    }
  }

  void _invalidateRemoteCompareForSharpTurn() {
    _lastRemoteCompareFetchLocation = null;
    _pendingRelaxedFirstRemoteCompareFetch = true;
    _remoteCompareSustainedStartUtcMs = 0;
    _remoteCompareFetchInFlight = false;
    _pendingRemoteCompareFetchLocation = null;
    _remoteCompareMph = null;
    if (!_primaryRemote) {
      SpeedLimitLoggingContext.setRemoteMphCell(null, false);
    }
  }

  void _invalidateRouteGeometryForSharpTurn() {
    _invalidatePrimaryRouteGeometryForSharpTurn();
    _invalidateTomTomCompareForSharpTurn();
    _invalidateMapboxCompareForSharpTurn();
    _invalidateHereCompareForSharpTurn();
    _invalidateRemoteCompareForSharpTurn();
  }

  void _enqueueHerePrimaryFetch(Position location, double displaySpeedMph) {
    if (_pipelinePaused) return;
    if (_primaryRouteFetchInFlight) {
      _pendingFetchLocation = location;
      _pendingFetchSpeedMph = displaySpeedMph;
      _emitSpeedUiOnly(displaySpeedMph, 'here_fetch_in_flight');
      return;
    }
    _primaryRouteFetchInFlight = true;
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

  void _enqueueRemotePrimaryFetch(Position location, double displaySpeedMph) {
    if (_pipelinePaused) return;
    if (_primaryRouteFetchInFlight) {
      _pendingFetchLocation = location;
      _pendingFetchSpeedMph = displaySpeedMph;
      _emitSpeedUiOnly(displaySpeedMph, 'remote_fetch_in_flight');
      return;
    }
    _primaryRouteFetchInFlight = true;
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
    unawaited(_runRemoteFetchChain(
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
      _hereStickyRoadSegment = null;
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
      _primaryRouteFetchInFlight = false;
      final next = _pendingFetchLocation;
      _pendingFetchLocation = null;
      _pendingFetchSpeedMph = null;
      if (next != null && generation == _speedFetchGeneration) {
        final nextPair = _effectiveSpeedMpsAndMph(next);
        final nextRaw = nextPair.$2;
        final nextDisplay = nextRaw;
        _maybeRequestHereFetch(next, nextRaw, nextDisplay);
      }
    }
  }

  Future<void> _runRemoteFetchChain(
    Position location,
    double displaySpeedMph,
    int generation,
    double? metersSincePriorFetch,
    int? msSincePriorFetch,
  ) async {
    try {
      await _runShortRemoteFetch(
        location,
        displaySpeedMph,
        generation,
        metersSincePriorFetch,
        msSincePriorFetch,
      );
    } catch (e, st) {
      _remoteStickyRoadSegment = null;
      _remoteSectionSpeedModel = null;
      _sectionWalkAlongContinuity.reset();
      assert(() {
        // ignore: avoid_print
        print('LocationProcessor Remote fetch failed: $e\n$st');
        return true;
      }());
      if (generation == _speedFetchGeneration) {
        onSpeedUpdate(displaySpeedMph, _currentSpeedLimitMph);
      }
    } finally {
      _primaryRouteFetchInFlight = false;
      final next = _pendingFetchLocation;
      _pendingFetchLocation = null;
      _pendingFetchSpeedMph = null;
      if (next != null && generation == _speedFetchGeneration) {
        final nextPair = _effectiveSpeedMpsAndMph(next);
        final nextMps = nextPair.$1;
        final nextRaw = nextPair.$2;
        final nextDisplay = nextRaw;
        if (_shouldFetchNewSpeedLimit(next, nextMps)) {
          _maybeRequestRemoteFetch(next, nextRaw, nextDisplay);
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

      SpeedFetchTelemetry? telemetryObj;
      if (logCompare) {
        telemetryObj = _speedFetchTelemetryFrom(
          t0Here,
          t1Here,
          resolvedHere,
          hereResult.stickySegment,
          rawMph == null ? resolvedHere.source : null,
        );
      }

      if (rawMph != null) {
        _hereStickyRoadSegment = hereResult.stickySegment;
        _sectionWalkAlongContinuity.reset();
        _hereSectionSpeedModel = hereResult.sectionSpeedModel;
        _applyPrimaryResolvedLimit(
          location: location,
          vehicleSpeedMph: vehicleSpeedMph,
          rawMph: rawMph,
          segmentKey: resolvedHere.segmentKey ?? hereResult.stickySegment?.linkId,
          functionalClass: resolvedHere.functionalClass,
          logCompareRow: logCompare,
          fetchTelemetry: telemetryObj,
          logFields: logFields,
          hereLimitFromNetworkFetch: true,
          hereResolvePath: 'network',
        );
      } else {
        _hereStickyRoadSegment = null;
        _hereSectionSpeedModel = null;
        _sectionWalkAlongContinuity.reset();
        SpeedLimitLoggingContext.updateRoadFunctionalClass(resolvedHere.functionalClass);
        if (logCompare && telemetryObj != null && logFields != null) {
          final peek = _vendorPeekMphForLogs();
          SpeedLimitLoggingContext.setHereAlertResolvePath('network_no_mph');
          await SpeedFetchDebugLogger.append(
            preferencesManager: preferencesManager,
            lat: location.latitude,
            lng: location.longitude,
            bearing: bearing,
            rawMph: -1,
            displayMph: -1,
            segmentKey: null,
            sourceTag: 'here',
            tomtomMph: peek.$1,
            mapboxMph: peek.$2,
            fetchTelemetry: telemetryObj,
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
          sourceTag: 'here_error',
          requestReasonHuman: _reasonHereFetchException,
          fetchTelemetry: SpeedFetchTelemetry(
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

  Future<void> _runShortRemoteFetch(
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
      final hereResult = await speedLimitAggregator.fetchRemoteForAlerts(
        lat: location.latitude,
        lng: location.longitude,
        headingDegrees: bearing,
      );
      final t1Here = logCompare ? SpeedFetchDebugLogger.utcNow() : '';

      if (generation != _speedFetchGeneration) return;

      final resolvedHere = hereResult.data;
      final rawMph = resolvedHere.speedLimitMph;
      if (generation != _speedFetchGeneration) return;

      SpeedFetchTelemetry? telemetryObj;
      if (logCompare) {
        telemetryObj = _speedFetchTelemetryFrom(
          t0Here,
          t1Here,
          resolvedHere,
          hereResult.stickySegment,
          rawMph == null ? resolvedHere.source : null,
        );
      }

      if (rawMph != null) {
        _remoteStickyRoadSegment = hereResult.stickySegment;
        _sectionWalkAlongContinuity.reset();
        _remoteSectionSpeedModel = hereResult.sectionSpeedModel;
        _remotePrimaryFromCache = resolvedHere.source.contains('(cached)');
        _applyPrimaryResolvedLimit(
          location: location,
          vehicleSpeedMph: vehicleSpeedMph,
          rawMph: rawMph,
          segmentKey: resolvedHere.segmentKey ?? hereResult.stickySegment?.linkId,
          functionalClass: resolvedHere.functionalClass,
          logCompareRow: logCompare,
          fetchTelemetry: telemetryObj,
          logFields: logFields,
          hereLimitFromNetworkFetch: !_remotePrimaryFromCache,
          hereResolvePath: _remotePrimaryFromCache ? 'remote_cache' : 'network',
        );
      } else {
        _remoteStickyRoadSegment = null;
        _remoteSectionSpeedModel = null;
        _sectionWalkAlongContinuity.reset();
        SpeedLimitLoggingContext.updateRoadFunctionalClass(resolvedHere.functionalClass);
        if (logCompare && telemetryObj != null && logFields != null) {
          final peek = _vendorPeekMphForLogs();
          SpeedLimitLoggingContext.setHereAlertResolvePath('network_no_mph');
          await SpeedFetchDebugLogger.append(
            preferencesManager: preferencesManager,
            lat: location.latitude,
            lng: location.longitude,
            bearing: bearing,
            rawMph: -1,
            displayMph: -1,
            segmentKey: null,
            sourceTag: 'remote',
            tomtomMph: peek.$1,
            mapboxMph: peek.$2,
            fetchTelemetry: telemetryObj,
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
          sourceTag: 'remote_error',
          requestReasonHuman: _reasonHereFetchException,
          fetchTelemetry: SpeedFetchTelemetry(
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

  void _maybeRequestTomTomPrimaryFetch(
    Position location,
    double rawMph,
    double displayMph,
  ) {
    if (!_shouldTriggerHereSpeedLimitFetch(location, rawMph)) {
      _emitSpeedUiOnly(displayMph, 'tomtom_fetch_gated');
      return;
    }
    _enqueueTomTomPrimaryFetch(location, displayMph);
  }

  void _enqueueTomTomPrimaryFetch(Position location, double displaySpeedMph) {
    if (_pipelinePaused) return;
    if (_tomtomCompareFetchInFlight) {
      _pendingTomTomCompareFetchLocation = location;
      _emitSpeedUiOnly(displaySpeedMph, 'tomtom_fetch_in_flight');
      return;
    }
    _tomtomCompareFetchInFlight = true;
    _pendingRelaxedFirstTomTomCompareFetch = false;
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
    _lastTomTomCompareFetchLocation = location;
    final generation = _speedFetchGeneration;
    unawaited(
      _runTomTomPrimaryFetchChain(
        location,
        displaySpeedMph,
        generation,
        metersSincePrev,
        msSincePrev,
      ),
    );
  }

  Future<void> _runTomTomPrimaryFetchChain(
    Position location,
    double displaySpeedMph,
    int generation,
    double? metersSincePriorFetch,
    int? msSincePriorFetch,
  ) async {
    try {
      await _runShortTomTomPrimaryFetch(
        location,
        displaySpeedMph,
        generation,
        metersSincePriorFetch,
        msSincePriorFetch,
      );
    } catch (e, st) {
      _tomtomRouteModel = null;
      _sectionWalkAlongContinuity.reset();
      assert(() {
        // ignore: avoid_print
        print('LocationProcessor TomTom primary fetch failed: $e\n$st');
        return true;
      }());
      if (generation == _speedFetchGeneration) {
        onSpeedUpdate(displaySpeedMph, _currentSpeedLimitMph);
      }
    } finally {
      _tomtomCompareFetchInFlight = false;
      final next = _pendingTomTomCompareFetchLocation;
      _pendingTomTomCompareFetchLocation = null;
      if (next != null && generation == _speedFetchGeneration) {
        final nextPair = _effectiveSpeedMpsAndMph(next);
        final nextMps = nextPair.$1;
        final nextRaw = nextPair.$2;
        final nextDisplay = nextRaw;
        if (_shouldFetchNewSpeedLimit(next, nextMps)) {
          _maybeRequestTomTomPrimaryFetch(next, nextRaw, nextDisplay);
        }
      }
    }
  }

  Future<void> _runShortTomTomPrimaryFetch(
    Position location,
    double vehicleSpeedMph,
    int generation,
    double? metersSincePriorFetch,
    int? msSincePriorFetch,
  ) async {
    final logCompare = preferencesManager.logSpeedFetchesToFile;
    final logFields = logCompare
        ? _FetchCycleLogFields(
            vehicleSpeedMph: vehicleSpeedMph,
            metersSincePriorFetch: metersSincePriorFetch,
            msSincePriorFetch: msSincePriorFetch,
            generation: generation,
          )
        : null;

    final bearing = AndroidLocationCompat.positionBearingIfHasBearing(location);
    final snapMps = _effectiveSpeedMpsAndMph(location).$1;
    final out = await tomTom.fetchSpeedLimit(
      latitude: location.latitude,
      longitude: location.longitude,
      headingDegrees: bearing,
      locationFixTimeUtcMs: location.timestamp.millisecondsSinceEpoch,
      speedMpsForSnapTiming: snapMps,
      polylineMatchingOptions: TomTomPolylineMatchingOptions.fromPosition(location),
    );

    if (generation != _speedFetchGeneration) return;

    final resolved = out.data;
    final rawMph = resolved.speedLimitMph;
    if (generation != _speedFetchGeneration) return;

    _tomtomRouteModel = out.sectionModel;
    if (rawMph != null) {
      _hereStickyRoadSegment = null;
      _remoteStickyRoadSegment = null;
      _hereSectionSpeedModel = null;
      _remoteSectionSpeedModel = null;
      _sectionWalkAlongContinuity.reset();
      _applyPrimaryResolvedLimit(
        location: location,
        vehicleSpeedMph: vehicleSpeedMph,
        rawMph: rawMph,
        segmentKey: resolved.segmentKey,
        functionalClass: resolved.functionalClass,
        logCompareRow: logCompare,
        fetchTelemetry: null,
        logFields: logFields,
        hereLimitFromNetworkFetch: true,
        hereResolvePath: 'network',
      );
    } else {
      _sectionWalkAlongContinuity.reset();
      SpeedLimitLoggingContext.updateRoadFunctionalClass(resolved.functionalClass);
      onSpeedUpdate(vehicleSpeedMph, _currentSpeedLimitMph);
    }
  }

  void _maybeRequestMapboxPrimaryFetch(
    Position location,
    double rawMph,
    double displayMph,
  ) {
    if (!_shouldTriggerHereSpeedLimitFetch(location, rawMph)) {
      _emitSpeedUiOnly(displayMph, 'mapbox_fetch_gated');
      return;
    }
    _enqueueMapboxPrimaryFetch(location, displayMph);
  }

  void _enqueueMapboxPrimaryFetch(Position location, double displaySpeedMph) {
    if (_pipelinePaused) return;
    if (_mapboxCompareFetchInFlight) {
      _pendingMapboxCompareFetchLocation = location;
      _emitSpeedUiOnly(displaySpeedMph, 'mapbox_fetch_in_flight');
      return;
    }
    _mapboxCompareFetchInFlight = true;
    _pendingRelaxedFirstMapboxCompareFetch = false;
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
    _lastMapboxCompareFetchLocation = location;
    final generation = _speedFetchGeneration;
    unawaited(
      _runMapboxPrimaryFetchChain(
        location,
        displaySpeedMph,
        generation,
        metersSincePrev,
        msSincePrev,
      ),
    );
  }

  Future<void> _runMapboxPrimaryFetchChain(
    Position location,
    double displaySpeedMph,
    int generation,
    double? metersSincePriorFetch,
    int? msSincePriorFetch,
  ) async {
    try {
      await _runShortMapboxPrimaryFetch(
        location,
        displaySpeedMph,
        generation,
        metersSincePriorFetch,
        msSincePriorFetch,
      );
    } catch (e, st) {
      _mapboxRouteModel = null;
      _sectionWalkAlongContinuity.reset();
      assert(() {
        // ignore: avoid_print
        print('LocationProcessor Mapbox primary fetch failed: $e\n$st');
        return true;
      }());
      if (generation == _speedFetchGeneration) {
        onSpeedUpdate(displaySpeedMph, _currentSpeedLimitMph);
      }
    } finally {
      _mapboxCompareFetchInFlight = false;
      final next = _pendingMapboxCompareFetchLocation;
      _pendingMapboxCompareFetchLocation = null;
      if (next != null && generation == _speedFetchGeneration) {
        final nextPair = _effectiveSpeedMpsAndMph(next);
        final nextMps = nextPair.$1;
        final nextRaw = nextPair.$2;
        final nextDisplay = nextRaw;
        if (_shouldFetchNewSpeedLimit(next, nextMps)) {
          _maybeRequestMapboxPrimaryFetch(next, nextRaw, nextDisplay);
        }
      }
    }
  }

  Future<void> _runShortMapboxPrimaryFetch(
    Position location,
    double vehicleSpeedMph,
    int generation,
    double? metersSincePriorFetch,
    int? msSincePriorFetch,
  ) async {
    final logCompare = preferencesManager.logSpeedFetchesToFile;
    final logFields = logCompare
        ? _FetchCycleLogFields(
            vehicleSpeedMph: vehicleSpeedMph,
            metersSincePriorFetch: metersSincePriorFetch,
            msSincePriorFetch: msSincePriorFetch,
            generation: generation,
          )
        : null;

    final bearing = AndroidLocationCompat.positionBearingIfHasBearing(location);
    final out = await mapbox.fetchSpeedLimit(
      latitude: location.latitude,
      longitude: location.longitude,
      headingDegrees: bearing,
      polylineMatchingOptions: MapboxPolylineMatchingOptions.fromPosition(location),
    );

    if (generation != _speedFetchGeneration) return;

    final resolved = out.data;
    final rawMph = resolved.speedLimitMph;
    if (generation != _speedFetchGeneration) return;

    _mapboxRouteModel = out.sectionModel;
    if (rawMph != null) {
      _hereStickyRoadSegment = null;
      _remoteStickyRoadSegment = null;
      _hereSectionSpeedModel = null;
      _remoteSectionSpeedModel = null;
      _sectionWalkAlongContinuity.reset();
      _applyPrimaryResolvedLimit(
        location: location,
        vehicleSpeedMph: vehicleSpeedMph,
        rawMph: rawMph,
        segmentKey: resolved.segmentKey,
        functionalClass: resolved.functionalClass,
        logCompareRow: logCompare,
        fetchTelemetry: null,
        logFields: logFields,
        hereLimitFromNetworkFetch: true,
        hereResolvePath: 'network',
      );
    } else {
      _sectionWalkAlongContinuity.reset();
      SpeedLimitLoggingContext.updateRoadFunctionalClass(resolved.functionalClass);
      onSpeedUpdate(vehicleSpeedMph, _currentSpeedLimitMph);
    }
  }

  /// Primary speed limit resolution (HERE, Remote, TomTom, or Mapbox per [PreferencesManager.resolvedPrimarySpeedLimitProvider]).
  ///
  /// [HereDownwardLimitDebouncer] applies when primary is HERE or Remote.
  void _applyPrimaryResolvedLimit({
    required Position location,
    required double vehicleSpeedMph,
    required int rawMph,
    required String? segmentKey,
    required int? functionalClass,
    bool logCompareRow = false,
    SpeedFetchTelemetry? fetchTelemetry,
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

    final displayMph = rawForPipeline;

    // HERE- or Remote-shaped primary: debounce downward limit changes. TomTom/Mapbox use [displayMph] as-is.
    final int finalDisplay;
    if (_primaryHere || _primaryRemote) {
      final segmentIdentityChanged =
          segmentKey != null && _lastHereSegmentKey != null && segmentKey != _lastHereSegmentKey;
      final immediateForDebounce = _forceImmediateLimitCommit || segmentIdentityChanged;
      _forceImmediateLimitCommit = false;
      finalDisplay = _hereDownwardLimitDebouncer.commit(
        displayMph,
        location.timestamp.millisecondsSinceEpoch,
        immediateForDebounce,
      );
    } else {
      _forceImmediateLimitCommit = false;
      finalDisplay = displayMph;
    }
    _currentSpeedLimitMph = finalDisplay.toDouble();
    if (_primaryHere) {
      SpeedLimitLoggingContext.setHereMphCell(finalDisplay, hereLimitFromNetworkFetch);
    } else if (_primaryRemote) {
      SpeedLimitLoggingContext.setRemoteMphCell(finalDisplay, hereLimitFromNetworkFetch);
    }
    if (logCompareRow) {
      final peek = _vendorPeekMphForLogs();
      final String sourceTag;
      if (_primaryHere) {
        sourceTag = 'here';
      } else if (_primaryRemote) {
        sourceTag = 'remote';
      } else if (_primaryTomTom) {
        sourceTag = 'tomtom';
      } else {
        sourceTag = 'mapbox';
      }
      unawaited(
        SpeedFetchDebugLogger.append(
          preferencesManager: preferencesManager,
          lat: location.latitude,
          lng: location.longitude,
          bearing: AndroidLocationCompat.positionBearingIfHasBearing(location),
          rawMph: rawForPipeline,
          displayMph: finalDisplay,
          segmentKey: segmentKey,
          sourceTag: sourceTag,
          tomtomMph: peek.$1,
          mapboxMph: peek.$2,
          fetchTelemetry: fetchTelemetry,
          vehicleSpeedMph: logFields?.vehicleSpeedMph,
          metersSincePriorFetchTrigger: logFields?.metersSincePriorFetch,
          msSincePriorFetchTrigger: logFields?.msSincePriorFetch,
          fetchGeneration: logFields?.generation,
          requestReasonHuman: _reasonHereFetchSuccessRow,
        ),
      );
    }
    // Do not record display limit change events per user request.
    onSpeedUpdate(vehicleSpeedMph, _currentSpeedLimitMph);
    _lastHereSegmentKey = segmentKey;
  }

  void _logDisplayLimitChangeIfChanged({
    required Position location,
    required double vehicleSpeedMph,
    required int stabilizerMph,
    required int finalDisplay,
    String? segmentKey,
  }) {
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

  static SpeedFetchTelemetry _speedFetchTelemetryFrom(
    String requestUtc,
    String responseUtc,
    SpeedLimitData data,
    RoadSegment? stickySegment,
    String? apiError,
  ) {
    return SpeedFetchTelemetry(
      requestUtc: requestUtc,
      responseUtc: responseUtc,
      responseSource: data.source,
      responseConfidence: data.confidence.name,
      functionalClass: data.functionalClass,
      segmentCacheZoneCount: stickySegment?.geometry.length,
      segmentCacheRouteLenM: stickySegment != null
          ? HereCrossTrackGeometry.polylineLengthMeters(stickySegment.geometry)
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
      'Primary fetch completed with a usable mph; row shows raw/display after downward debouncer.';
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
