import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../providers/driving_session_notifier.dart';
import '../services/overlay_permission_platform.dart';
import '../services/preferences_manager.dart';
import '../screens/settings_screen.dart';
import '../screens/testing_screen.dart';
import '../widgets/speed_session_summary_card.dart';
import '../core/constants.dart';
import '../config/app_config.dart';
import '../services/app_permissions.dart';
import '../services/system_ui.dart';
import 'package:flutter/services.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  DateTime? _lastBeepUtc;

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

    final liveDrivingActive = drive.isTracking &&
        !drive.isSimulating &&
        drive.userStartedLiveDriving;
    final simulationRunningOnSession =
        drive.isTracking && drive.isSimulating;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Speed Alert Pro'),
        actions: [
          IconButton(
            icon: const Icon(Icons.science_outlined),
            tooltip: 'Simulation',
            onPressed: () async {
              if (drive.isTracking && !drive.isSimulating) {
                await notifier.stopTracking();
              }
              if (context.mounted) {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TestingScreen(),
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SpeedSessionSummaryCard(
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
              remoteFromCache: drive.remoteLimitFromCache,
              alertThresholdMph: threshold,
              suppressAlertsUnder15Mph: preferencesManager.suppressAlertsWhenUnder15Mph,
            ),
            const SizedBox(height: 16),
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
                'Road test simulation is active. Stop it from Simulation mode.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (drive.lastError != null) ...[
              const SizedBox(height: 8),
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
              const SizedBox(height: 4),
              OutlinedButton(
                onPressed: () => AppPermissions.openSettings(),
                child: const Text('Open Settings'),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Alert mode',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            RadioListTile<int>(
              value: AlertRunMode.normal,
              groupValue: preferencesManager.alertRunMode,
              title: const Text('In-app only'),
              subtitle: const Text('Visual and audible alerts while the app is visible'),
              onChanged: (v) {
                if (v != null) {
                  preferencesManager.alertRunMode = v;
                  ref.read(prefsRevisionProvider.notifier).state++;
                }
              },
            ),
            RadioListTile<int>(
              value: AlertRunMode.backgroundSound,
              groupValue: preferencesManager.alertRunMode,
              title: const Text('Background sound'),
              subtitle: const Text('Audible speed alerts even when using other apps'),
              secondary: FilledButton.tonal(
                onPressed: () async {
                  final ok = await SettingsScreen.requestBackgroundPermissions(context);
                  if (!context.mounted) return;
                  if (!ok) {
                    preferencesManager.alertRunMode = AlertRunMode.normal;
                    ref.read(prefsRevisionProvider.notifier).state++;
                    return;
                  }
                  preferencesManager.alertRunMode = AlertRunMode.backgroundSound;
                  ref.read(prefsRevisionProvider.notifier).state++;
                  await Future.delayed(const Duration(milliseconds: 50));
                  if (context.mounted) {
                    await SystemUi.moveTaskToBack();
                  }
                },
                child: const Text('Go'),
              ),
              onChanged: (v) {
                if (v != null) {
                  preferencesManager.alertRunMode = v;
                  ref.read(prefsRevisionProvider.notifier).state++;
                }
              },
            ),
            RadioListTile<int>(
              value: AlertRunMode.backgroundOverlay,
              groupValue: preferencesManager.alertRunMode,
              title: const Text('Overlay + sound'),
              subtitle: const Text('Floating speed HUD and alerts over other apps'),
              secondary: FilledButton.tonal(
                onPressed: () async {
                  final ok = await SettingsScreen.requestBackgroundPermissions(context);
                  if (!context.mounted) return;
                  if (!ok) {
                    preferencesManager.alertRunMode = AlertRunMode.normal;
                    ref.read(prefsRevisionProvider.notifier).state++;
                    return;
                  }
                  // Location + battery done, now check overlay
                  final overlayGranted = await OverlayPermissionPlatform.isOverlayPermissionGranted();
                  if (!context.mounted) return;
                  if (!overlayGranted) {
                    preferencesManager.alertRunMode = AlertRunMode.backgroundOverlay;
                    ref.read(prefsRevisionProvider.notifier).state++;
                    // Open overlay settings — user comes back and taps Go again
                    unawaited(OverlayPermissionPlatform.primeAttemptAndOpenManageScreen());
                    return;
                  }
                  // All permissions granted — set mode, show overlay immediately, then minimize
                  preferencesManager.alertRunMode = AlertRunMode.backgroundOverlay;
                  ref.read(prefsRevisionProvider.notifier).state++;
                  ref.read(drivingSessionProvider.notifier).syncOverlayNow();
                  await Future.delayed(const Duration(milliseconds: 50));
                  if (context.mounted) {
                    await SystemUi.moveTaskToBack();
                  }
                },
                child: const Text('Go'),
              ),
              onChanged: (v) {
                if (v != null) {
                  preferencesManager.alertRunMode = v;
                  ref.read(prefsRevisionProvider.notifier).state++;
                }
              },
            ),
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                title: const Text('Audible overspeed alert'),
                value: preferencesManager.isAudibleAlertEnabled,
                onChanged: (v) {
                  preferencesManager.isAudibleAlertEnabled = v;
                  ref.read(prefsRevisionProvider.notifier).state++;
                },
              ),
            ),
            Card(
              child: SwitchListTile(
                title: const Text('Silent when speed limit < 15 mph'),
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
    );
  }

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
    unawaited(HapticFeedback.heavyImpact());
  }
}