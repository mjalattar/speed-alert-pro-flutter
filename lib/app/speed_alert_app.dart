import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../providers/app_providers.dart';
import '../screens/main_shell_screen.dart';
import '../services/overlay_dart_handlers.dart';
import '../widgets/app_root_gate.dart';
import 'route_observer.dart';
import 'speed_alert_application_bootstrap.dart';
import 'theme.dart';

class SpeedAlertApp extends ConsumerStatefulWidget {
  const SpeedAlertApp({super.key});

  @override
  ConsumerState<SpeedAlertApp> createState() => _SpeedAlertAppState();
}

class _SpeedAlertAppState extends ConsumerState<SpeedAlertApp> {
  @override
  void initState() {
    super.initState();
    registerOverlayDartHandlers(ref);

    // Run auth bootstrap after the first frame renders so UI appears immediately.
    if (AppConfig.useRemoteHere && AppConfig.supabaseUrl.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        runSupabaseAuthBootstrap();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferencesManager =
        ref.watch(preferencesProvider).preferencesManager;
    final mode = themeModeForPrefs(preferencesManager.uiThemeMode);

    return MaterialApp(
      title: 'Speed Alert Pro',
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      themeMode: mode,
      navigatorObservers: [appRouteObserver],
      home: const AppRootGate(child: MainShellScreen()),
    );
  }
}