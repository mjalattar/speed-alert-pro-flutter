import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../core/constants.dart';
import '../providers/app_providers.dart';
import '../services/overlay_permission_platform.dart';
import '../widgets/simulation_destination_settings.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferencesManager = ref.watch(preferencesProvider).preferencesManager;

    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        unawaited(
          preferencesManager.flushSimulationFormInputsToDisk(
            routingOriginLatLng: preferencesManager.simulationRoutingOriginLatLng,
            routingDestinationLatLng:
                preferencesManager.simulationRoutingDestinationLatLng,
            customDestinationQuery:
                preferencesManager.simulationCustomDestinationQuery,
            customDestinationLatLng:
                preferencesManager.simulationDestinationPreset == 4
                    ? preferencesManager.simulationCustomDestinationLatLng
                    : null,
          ),
        );
      },
      child: Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Alerts', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            title: const Text('Audible overspeed alert'),
            value: preferencesManager.isAudibleAlertEnabled,
            onChanged: (v) {
              preferencesManager.isAudibleAlertEnabled = v;
              ref.read(prefsRevisionProvider.notifier).state++;
            },
          ),
          SwitchListTile(
            title: const Text('Suppress alerts under 15 mph'),
            subtitle: const Text('Same as Android LOW_SPEED_ALERT_SUPPRESS_BELOW_MPH'),
            value: preferencesManager.suppressAlertsWhenUnder15Mph,
            onChanged: (v) {
              preferencesManager.suppressAlertsWhenUnder15Mph = v;
              ref.read(prefsRevisionProvider.notifier).state++;
            },
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('Overspeed threshold: +${preferencesManager.alertThresholdMph} mph'),
              ),
              Slider(
                value: preferencesManager.alertThresholdMph.toDouble(),
                min: 0,
                max: 20,
                divisions: 20,
                label: '${preferencesManager.alertThresholdMph}',
                onChanged: (x) {
                  preferencesManager.alertThresholdMph = x.round();
                  ref.read(prefsRevisionProvider.notifier).state++;
                },
              ),
            ],
          ),
          const Divider(),
          Text('Alert run mode', style: Theme.of(context).textTheme.titleMedium),
          RadioListTile<int>(
            title: const Text('Normal (in-app only)'),
            subtitle: const Text(
              'Audible alerts only while the app is visible. '
              'When you leave the app, HERE speed processing pauses (same as Android).',
            ),
            value: AlertRunMode.normal,
            groupValue: preferencesManager.alertRunMode,
            onChanged: (v) {
              if (v != null) {
                preferencesManager.alertRunMode = v;
                ref.read(prefsRevisionProvider.notifier).state++;
              }
            },
          ),
          RadioListTile<int>(
            title: const Text('Background sound'),
            value: AlertRunMode.backgroundSound,
            groupValue: preferencesManager.alertRunMode,
            onChanged: (v) {
              if (v != null) {
                preferencesManager.alertRunMode = v;
                ref.read(prefsRevisionProvider.notifier).state++;
              }
            },
          ),
          RadioListTile<int>(
            title: const Text('Background overlay'),
            subtitle: const Text(
              'Audible + MethodChannel overlay HUD when another app is on screen (register '
              'speed_alert_pro/overlay in Android MainActivity; grant “display over other apps”).',
            ),
            value: AlertRunMode.backgroundOverlay,
            groupValue: preferencesManager.alertRunMode,
            onChanged: (v) {
              if (v != null) {
                preferencesManager.alertRunMode = v;
                ref.read(prefsRevisionProvider.notifier).state++;
                if (v == AlertRunMode.backgroundOverlay) {
                  unawaited(
                    OverlayPermissionPlatform.primeAttemptAndOpenManageScreen(),
                  );
                }
              }
            },
          ),
          if (preferencesManager.alertRunMode == AlertRunMode.backgroundOverlay)
            SwitchListTile(
              title: const Text('Overlay HUD minimized'),
              subtitle: const Text(
                'Same as − on the Kotlin HUD: hide floating overlay until the app is foreground again.',
              ),
              value: preferencesManager.isOverlayHudMinimized,
              onChanged: (v) {
                preferencesManager.isOverlayHudMinimized = v;
                ref.read(prefsRevisionProvider.notifier).state++;
              },
            ),
          const Divider(),
          Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
          RadioListTile<int>(
            title: const Text('System'),
            value: AppThemeMode.auto,
            groupValue: preferencesManager.uiThemeMode,
            onChanged: (v) {
              if (v != null) {
                preferencesManager.uiThemeMode = v;
                ref.read(prefsRevisionProvider.notifier).state++;
              }
            },
          ),
          RadioListTile<int>(
            title: const Text('Light'),
            value: AppThemeMode.light,
            groupValue: preferencesManager.uiThemeMode,
            onChanged: (v) {
              if (v != null) {
                preferencesManager.uiThemeMode = v;
                ref.read(prefsRevisionProvider.notifier).state++;
              }
            },
          ),
          RadioListTile<int>(
            title: const Text('Dark'),
            value: AppThemeMode.dark,
            groupValue: preferencesManager.uiThemeMode,
            onChanged: (v) {
              if (v != null) {
                preferencesManager.uiThemeMode = v;
                ref.read(prefsRevisionProvider.notifier).state++;
              }
            },
          ),
          const Divider(),
          Text('APIs', style: Theme.of(context).textTheme.titleMedium),
          Text(
            'Speed limit data source',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          RadioListTile<bool>(
            title: const Text('On this device (local keys)'),
            value: false,
            groupValue: preferencesManager.useRemoteSpeedApi,
            onChanged: (v) {
              if (v != true) {
                preferencesManager.useRemoteSpeedApi = false;
                ref.read(prefsRevisionProvider.notifier).state++;
              }
            },
          ),
          RadioListTile<bool>(
            title: const Text('Remote (Supabase Edge)'),
            subtitle: AppConfig.useRemoteHere
                ? const Text(
                    'Requires Google sign-in when remote is enforced',
                  )
                : null,
            value: true,
            groupValue: preferencesManager.useRemoteSpeedApi,
            onChanged: (v) {
              if (v != true) return;
              if (!AppConfig.useRemoteHere) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Add your Supabase URL to local.properties as '
                      'supabase.url=https://YOUR-REF.supabase.co then rebuild (Kotlin), '
                      'or pass --dart-define=SUPABASE_URL=... for Flutter (see README).',
                    ),
                  ),
                );
                return;
              }
              preferencesManager.useRemoteSpeedApi = true;
              ref.read(prefsRevisionProvider.notifier).state++;
            },
          ),
          Text(
            'Local HERE tuning',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SwitchListTile(
            title: const Text('Local speed stabilizer'),
            subtitle: const Text(
              'Same gate as Kotlin: applies when not using remote Edge for HERE alerts.',
            ),
            value: preferencesManager.useLocalSpeedStabilizer,
            onChanged: (v) {
              preferencesManager.useLocalSpeedStabilizer = v;
              ref.read(prefsRevisionProvider.notifier).state++;
            },
          ),
          SwitchListTile(
            title: const Text('Log speed fetches to file'),
            subtitle: const Text(
              'Kotlin PreferencesManager.logSpeedFetchesToFile — unified CSV + HTTP rows when driving or simulating.',
            ),
            value: preferencesManager.logSpeedFetchesToFile,
            onChanged: (v) {
              preferencesManager.logSpeedFetchesToFile = v;
              ref.read(prefsRevisionProvider.notifier).state++;
            },
          ),
          Text(
            'API providers',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SwitchListTile(
            title: const Text('HERE (alerts)'),
            value: preferencesManager.isHereApiEnabled,
            onChanged: (v) {
              preferencesManager.isHereApiEnabled = v;
              ref.read(prefsRevisionProvider.notifier).state++;
            },
          ),
          SwitchListTile(
            title: const Text('TomTom (compare)'),
            subtitle: const Text('Same toggle as Kotlin PreferencesManager.'),
            value: preferencesManager.isTomTomApiEnabled,
            onChanged: (v) {
              preferencesManager.isTomTomApiEnabled = v;
              ref.read(prefsRevisionProvider.notifier).state++;
            },
          ),
          SwitchListTile(
            title: const Text('Mapbox (compare — UI hook)'),
            value: preferencesManager.isMapboxApiEnabled,
            onChanged: (v) {
              preferencesManager.isMapboxApiEnabled = v;
              ref.read(prefsRevisionProvider.notifier).state++;
            },
          ),
          const Divider(),
          const SimulationDestinationSettings(),
          const Divider(),
          ListTile(
            title: const Text('Configuration'),
            subtitle: Text(
              'HERE key & Supabase: pass --dart-define at build time '
              '(see README in speed-alert-pro-flutter).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
      ),
    );
  }
}
