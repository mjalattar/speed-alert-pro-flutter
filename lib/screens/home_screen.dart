import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../app/route_observer.dart';
import '../config/app_config.dart';
import '../core/constants.dart';
import '../providers/app_providers.dart';
import '../services/preferences_manager.dart';
import '../providers/driving_session_notifier.dart';
import '../logging/speed_limit_api_session_counter.dart';
import '../widgets/speed_session_summary_card.dart';
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.tabActive = true});

  /// When false (other bottom tab selected), the map platform view is not built
  /// so it cannot composite above other routes.
  final bool tabActive;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with RouteAware {
  DateTime? _lastBeepUtc;

  /// Another route (e.g. Settings) was pushed on top of this screen.
  bool _coveredByRoute = false;

  bool _routeObserverSubscribed = false;

  static const _defaultMapTarget = LatLng(29.5445, -95.0205);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeObserverSubscribed) return;
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) {
      appRouteObserver.subscribe(this, route);
      _routeObserverSubscribed = true;
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() {
    setState(() => _coveredByRoute = true);
  }

  @override
  void didPopNext() {
    setState(() => _coveredByRoute = false);
  }

  @override
  Widget build(BuildContext context) {
    final preferencesManager = ref.watch(preferencesProvider).preferencesManager;
    final drive = ref.watch(drivingSessionProvider);
    final notifier = ref.read(drivingSessionProvider.notifier);

    ref.listen<DrivingSessionState>(drivingSessionProvider, (prev, next) {
      _maybeAudibleAlert(
        ref.read(preferencesProvider).preferencesManager,
        ref.read(appForegroundVisibleProvider),
        next,
      );
    });
    ref.listen<bool>(appForegroundVisibleProvider, (prev, next) {
      _maybeAudibleAlert(
        ref.read(preferencesProvider).preferencesManager,
        next,
        ref.read(drivingSessionProvider),
      );
    });

    final threshold = preferencesManager.alertThresholdMph;

    final hasMapKey = AppConfig.googleMapsApiKey.isNotEmpty;
    final h = MediaQuery.sizeOf(context).height;
    final mapHeight = hasMapKey
        ? (h * 0.33).clamp(160.0, 360.0)
        : 0.0;

    final showPlatformMap =
        hasMapKey && mapHeight > 0 && widget.tabActive && !_coveredByRoute;

    /// Live GPS the user explicitly started from Drive — not simulation-only pipeline.
    final liveDrivingActive = drive.isTracking &&
        !drive.isSimulating &&
        drive.userStartedLiveDriving;
    final simulationRunningOnSession =
        drive.isTracking && drive.isSimulating;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SpeedSessionSummaryCard(
              primaryProviderLabel:
                  preferencesManager.resolvedPrimarySpeedLimitProviderDisplayName,
              isTestingTab: false,
              isSimulating: drive.isSimulating,
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
              alertThresholdMph: threshold,
              suppressAlertsUnder15Mph: preferencesManager.suppressAlertsWhenUnder15Mph,
            ),
          ),
          if (hasMapKey && mapHeight > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SizedBox(
                height: mapHeight,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(12),
                  ),
                  child: showPlatformMap
                      ? GoogleMap(
                          initialCameraPosition: const CameraPosition(
                            target: _defaultMapTarget,
                            zoom: 12,
                          ),
                          myLocationEnabled: true,
                          myLocationButtonEnabled: true,
                          mapToolbarEnabled: false,
                        )
                      : ColoredBox(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: const Center(
                            child: Icon(Icons.map_outlined, size: 40),
                          ),
                        ),
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Location tracking',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          ValueListenableBuilder<int>(
                            valueListenable:
                                SpeedLimitApiSessionCounter.hereRoutingDrivingSessionCount,
                            builder: (context, hereReqCount, _) {
                              return Text(
                                'HERE speed-limit API requests (this session): $hereReqCount',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                              );
                            },
                          ),
                          const SizedBox(height: 4),
                          ValueListenableBuilder<int>(
                            valueListenable:
                                SpeedLimitApiSessionCounter.remoteEdgeDrivingSessionCount,
                            builder: (context, remoteReqCount, _) {
                              return Text(
                                'Remote (Supabase Edge) requests (this session): $remoteReqCount',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: simulationRunningOnSession
                                ? null
                                : liveDrivingActive
                                    ? () => notifier.stopTracking()
                                    : () => notifier.startTracking(),
                            icon: Icon(
                              simulationRunningOnSession
                                  ? Icons.route
                                  : liveDrivingActive
                                      ? Icons.stop
                                      : Icons.play_arrow,
                            ),
                            label: Text(
                              simulationRunningOnSession
                                  ? 'Simulation running'
                                  : liveDrivingActive
                                      ? 'Stop tracking'
                                      : 'Start tracking',
                            ),
                          ),
                          if (simulationRunningOnSession) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Road test simulation is active. Stop it from the Testing tab.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (drive.lastError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      drive.lastError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (drive.permissionDenied) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Location permission is required. Enable it in system settings.',
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Alert mode: ${_modeLabel(preferencesManager.alertRunMode)} · threshold +$threshold mph',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: SwitchListTile(
                      title: const Text('Suppress alerts under 15 mph'),
                      value: preferencesManager.suppressAlertsWhenUnder15Mph,
                      onChanged: (v) {
                        preferencesManager.suppressAlertsWhenUnder15Mph = v;
                        ref.read(prefsRevisionProvider.notifier).state++;
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _modeLabel(int mode) {
    switch (mode) {
      case AlertRunMode.backgroundSound:
        return 'Background sound';
      case AlertRunMode.backgroundOverlay:
        return 'Background overlay (see mobile roadmap)';
      default:
        return 'In-app only';
    }
  }

  /// Plays debounced beeps when speeding per alert mode and foreground rules.
  void _maybeAudibleAlert(
    PreferencesManager preferencesManager,
    bool appInForeground,
    DrivingSessionState next,
  ) {
    if (!preferencesManager.isAudibleAlertEnabled) return;
    final threshold = preferencesManager.alertThresholdMph;
    if (!next.isSpeeding(
      threshold,
      preferencesManager.suppressAlertsWhenUnder15Mph,
    )) {
      return;
    }
    final shouldPlay = switch (preferencesManager.alertRunMode) {
      AlertRunMode.normal => appInForeground,
      AlertRunMode.backgroundSound => true,
      AlertRunMode.backgroundOverlay => true,
      _ => false,
    };
    if (!shouldPlay) return;

    final now = DateTime.now();
    if (_lastBeepUtc != null &&
        now.difference(_lastBeepUtc!) < const Duration(seconds: 3)) {
      return;
    }
    _lastBeepUtc = now;
    unawaited(SystemSound.play(SystemSoundType.alert));
  }
}
