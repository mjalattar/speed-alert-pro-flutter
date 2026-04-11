import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/app_config.dart';
import '../core/constants.dart';
import '../engine/shared/geo_coordinate.dart';
import '../logging/speed_limit_api_session_counter.dart';
import '../providers/app_providers.dart';
import '../providers/driving_session_notifier.dart';
import '../widgets/simulation_destination_settings.dart';
import '../widgets/speed_session_summary_card.dart';

/// Testing tab: speed/limit card, map, and road-test simulator.
class TestingScreen extends ConsumerStatefulWidget {
  const TestingScreen({super.key});

  @override
  ConsumerState<TestingScreen> createState() => _TestingScreenState();
}

class _TestingScreenState extends ConsumerState<TestingScreen> {
  static const _leagueCity = LatLng(29.5445, -95.0205);
  static const _polylineId = PolylineId('sim_route');
  static const _vehicleMarkerId = MarkerId('sim_vehicle');

  GoogleMapController? _mapController;

  /// Fit camera bounds once per route; then follow the simulated vehicle marker.
  void _fitSimulationRoute(List<GeoCoordinate> route) {
    final c = _mapController;
    if (!mounted || c == null || route.length < 2) return;
    var minLat = route.first.lat;
    var maxLat = route.first.lat;
    var minLng = route.first.lng;
    var maxLng = route.first.lng;
    for (final p in route.skip(1)) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLng = math.min(minLng, p.lng);
      maxLng = math.max(maxLng, p.lng);
    }
    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
    c.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
  }

  void _scheduleFitSimulationRoute(List<GeoCoordinate> route) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fitSimulationRoute(route);
    });
  }

  @override
  Widget build(BuildContext context) {
    final preferencesManager =
        ref.watch(preferencesProvider).preferencesManager;
    final drive = ref.watch(drivingSessionProvider);
    final notifier = ref.read(drivingSessionProvider.notifier);
    final simAnchor = ref.watch(simulationMapAnchorProvider);

    ref.listen(drivingSessionProvider, (prev, next) {
      final route = next.simulationRoutePolyline;
      if (route.length < 2) return;
      final prevRoute = prev?.simulationRoutePolyline ?? const <GeoCoordinate>[];
      final routeChanged = prevRoute.length != route.length ||
          (prevRoute.isNotEmpty &&
              (prevRoute.first.lat != route.first.lat ||
                  prevRoute.first.lng != route.first.lng));
      final simJustStarted =
          next.isSimulating && (prev?.isSimulating != true);
      if (routeChanged || simJustStarted) {
        _scheduleFitSimulationRoute(route);
      }
    });

    ref.listen(simulationMapAnchorProvider, (prev, next) {
      if (next == null) return;
      if (!ref.read(drivingSessionProvider).isSimulating) return;
      final c = _mapController;
      if (c == null) return;
      c.moveCamera(
        CameraUpdate.newLatLng(LatLng(next.lat, next.lng)),
      );
    });

    if (AppConfig.googleMapsApiKey.isEmpty) {
      return Scaffold(
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Add GOOGLE_MAPS_API_KEY (AppConfig) or --dart-define, and ensure AndroidManifest '
              'meta-data after flutter create.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final h = MediaQuery.sizeOf(context).height;
    final mapHeight = (h * 0.33).clamp(160.0, 360.0);
    final edge = ref.watch(remoteEdgeFunctionClientProvider);
    final canSimViaRemote = AppConfig.useRemoteHere &&
        preferencesManager.isRemoteApiEnabled &&
        edge != null;
    final canRunSimulation =
        preferencesManager.isHereApiEnabled || canSimViaRemote;

    Future<void> toggleSimulation() async {
      if (drive.isSimulating) {
        await notifier.stopRouteSimulation();
        return;
      }
      if (!canRunSimulation) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Enable HERE Maps or Remote API in the APIs section below.',
              ),
            ),
          );
        }
        return;
      }
      await notifier.startRouteSimulation();
    }

    final routePts = drive.simulationRoutePolyline;
    final polylines = <Polyline>{};
    if (routePts.length >= 2) {
      polylines.add(
        Polyline(
          polylineId: _polylineId,
          points: routePts.map((p) => LatLng(p.lat, p.lng)).toList(),
          color: Theme.of(context).colorScheme.primary,
          width: 5,
        ),
      );
    }

    final markers = <Marker>{};
    if (drive.isSimulating && simAnchor != null) {
      markers.add(
        Marker(
          markerId: _vehicleMarkerId,
          position: LatLng(simAnchor.lat, simAnchor.lng),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Simulation Mode'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SpeedSessionSummaryCard(
              primaryProviderLabel:
                  preferencesManager.resolvedPrimarySpeedLimitProviderDisplayName,
              isTestingTab: true,
              isSimulating: drive.isSimulating,
              isTracking: drive.isTracking,
              gpsSpeedMph: drive.speedMph,
              simulatedSpeedMph: drive.simulatedSpeedMph,
              limitMph: drive.limitMph,
              resolvedPrimarySpeedLimitProvider:
                  preferencesManager.resolvedPrimarySpeedLimitProvider,
              hereMph: preferencesManager.resolvedPrimarySpeedLimitProvider ==
                      SpeedLimitPrimaryProvider.here
                  ? drive.limitMph?.round()
                  : drive.hereCompareMph,
              tomTomMph: drive.tomTomMph,
              mapboxMph: drive.mapboxMph,
              remoteCompareEnabled: AppConfig.useRemoteHere,
              remoteMph: preferencesManager.resolvedPrimarySpeedLimitProvider ==
                      SpeedLimitPrimaryProvider.remote
                  ? drive.limitMph?.round()
                  : drive.remoteCompareMph,
              remoteFromCache: drive.remoteLimitFromCache,
              alertThresholdMph: preferencesManager.alertThresholdMph,
              suppressAlertsUnder15Mph:
                  preferencesManager.suppressAlertsWhenUnder15Mph,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: mapHeight,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
                child: GoogleMap(
                  initialCameraPosition: const CameraPosition(
                    target: _leagueCity,
                    zoom: 12,
                  ),
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,
                  mapToolbarEnabled: false,
                  polylines: polylines,
                  markers: markers,
                  onMapCreated: (c) {
                    _mapController = c;
                    final r =
                        ref.read(drivingSessionProvider).simulationRoutePolyline;
                    if (r.length >= 2) {
                      _scheduleFitSimulationRoute(r);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'APIs',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Main speed limit (display + alerts)',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    RadioListTile<int>(
                      title: const Text('HERE Maps'),
                      value: SpeedLimitPrimaryProvider.here,
                      groupValue: preferencesManager.primarySpeedLimitProvider,
                      onChanged: (v) {
                        if (v != null) {
                          preferencesManager.primarySpeedLimitProvider = v;
                          preferencesManager.isHereApiEnabled = true;
                          ref.read(prefsRevisionProvider.notifier).state++;
                        }
                      },
                    ),
                    RadioListTile<int>(
                      title: const Text('TomTom'),
                      value: SpeedLimitPrimaryProvider.tomTom,
                      groupValue: preferencesManager.primarySpeedLimitProvider,
                      onChanged: (v) {
                        if (v != null) {
                          preferencesManager.primarySpeedLimitProvider = v;
                          preferencesManager.isTomTomApiEnabled = true;
                          ref.read(prefsRevisionProvider.notifier).state++;
                        }
                      },
                    ),
                    RadioListTile<int>(
                      title: const Text('Mapbox'),
                      value: SpeedLimitPrimaryProvider.mapbox,
                      groupValue: preferencesManager.primarySpeedLimitProvider,
                      onChanged: (v) {
                        if (v != null) {
                          preferencesManager.primarySpeedLimitProvider = v;
                          preferencesManager.isMapboxApiEnabled = true;
                          ref.read(prefsRevisionProvider.notifier).state++;
                        }
                      },
                    ),
                    RadioListTile<int>(
                      title: const Text('Remote'),
                      subtitle: AppConfig.useRemoteHere
                          ? const Text('Uses your Supabase Edge pipeline when enabled below.')
                          : const Text(
                              'Configure Supabase (see README) to use Remote as primary.',
                            ),
                      value: SpeedLimitPrimaryProvider.remote,
                      groupValue: preferencesManager.primarySpeedLimitProvider,
                      onChanged: (v) {
                        if (v == null) return;
                        if (!AppConfig.useRemoteHere) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Add your Supabase URL to local.properties as '
                                'supabase.url=https://YOUR-REF.supabase.co then rebuild the native app, '
                                'or pass --dart-define=SUPABASE_URL=... for Flutter (see README).',
                              ),
                            ),
                          );
                          return;
                        }
                        preferencesManager.primarySpeedLimitProvider = v;
                        preferencesManager.isRemoteApiEnabled = true;
                        ref.read(prefsRevisionProvider.notifier).state++;
                      },
                    ),
                    Text(
                      'API providers (choosing a main source above enables that provider here)',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    SwitchListTile(
                      title: const Text('HERE Maps'),
                      value: preferencesManager.isHereApiEnabled,
                      onChanged: (v) {
                        preferencesManager.isHereApiEnabled = v;
                        ref.read(prefsRevisionProvider.notifier).state++;
                      },
                    ),
                    SwitchListTile(
                      title: const Text('TomTom'),
                      subtitle: const Text('TomTom API key via --dart-define (see README).'),
                      value: preferencesManager.isTomTomApiEnabled,
                      onChanged: (v) {
                        preferencesManager.isTomTomApiEnabled = v;
                        ref.read(prefsRevisionProvider.notifier).state++;
                      },
                    ),
                    SwitchListTile(
                      title: const Text('Mapbox'),
                      subtitle: const Text('Mapbox Directions (public pk. token).'),
                      value: preferencesManager.isMapboxApiEnabled,
                      onChanged: (v) {
                        preferencesManager.isMapboxApiEnabled = v;
                        ref.read(prefsRevisionProvider.notifier).state++;
                      },
                    ),
                    if (AppConfig.useRemoteHere)
                      SwitchListTile(
                        title: const Text('Remote'),
                        subtitle: const Text('Supabase Edge — required when Remote is the main source.'),
                        value: preferencesManager.isRemoteApiEnabled,
                        onChanged: (v) {
                          preferencesManager.isRemoteApiEnabled = v;
                          ref.read(prefsRevisionProvider.notifier).state++;
                        },
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const SimulationDestinationSettings(),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Road Test Simulator',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    ValueListenableBuilder<int>(
                      valueListenable:
                          SpeedLimitApiSessionCounter.hereRoutingTestSessionCount,
                      builder: (context, hereReqCount, _) {
                        return Text(
                          'HERE speed-limit API requests (this test): $hereReqCount',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                    ValueListenableBuilder<int>(
                      valueListenable:
                          SpeedLimitApiSessionCounter.remoteEdgeTestSessionCount,
                      builder: (context, remoteReqCount, _) {
                        return Text(
                          'Remote (Supabase Edge) requests (this test): $remoteReqCount',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        );
                      },
                    ),
                    if (drive.isSimulating) ...[
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Current sim speed: ${drive.simulatedSpeedMph} mph',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: () =>
                                    notifier.adjustSimulatedSpeed(-5),
                                icon: const Icon(Icons.remove),
                              ),
                              IconButton(
                                onPressed: () =>
                                    notifier.adjustSimulatedSpeed(5),
                                icon: const Icon(Icons.add),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (drive.lastError != null) ...[
                      Text(
                        drive.lastError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    FilledButton(
                      onPressed: () async {
                        await toggleSimulation();
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: drive.isSimulating
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                      child: Text(
                        drive.isSimulating
                            ? 'Stop Test'
                            : 'Start Simulation Test',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
