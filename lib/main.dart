import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/speed_alert_application_bootstrap.dart';
import 'app/speed_alert_app.dart';
import 'config/app_config.dart';
import 'config/load_app_env.dart';
import 'logging/logging_globals.dart';
import 'logging/speed_alert_log_filesystem.dart';
import 'providers/app_providers.dart';
import 'services/preferences_manager.dart';

/// Application startup: initialize logging, shared preferences, RevenueCat when configured,
/// and Supabase when remote HERE is enabled.
///
/// The location pipeline starts only when the user begins driving tracking — not here
/// (see [DrivingSessionNotifier.startTracking]).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await loadAppEnv();

  await SpeedAlertLogFilesystem.init();

  PreferencesManager.registerAndroidSharedPrefsAllowListBeforeOpen();
  final preferencesManager = await PreferencesManager.open();
  initializePreferences(preferencesManager);
  speedAlertLoggingPreferences = preferencesManager;

  if (AppConfig.revenueCatPublicApiKey.isNotEmpty) {
    await Purchases.configure(
      PurchasesConfiguration(AppConfig.revenueCatPublicApiKey),
    );
  }

  if (AppConfig.useRemoteHere && AppConfig.supabaseUrl.isNotEmpty) {
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        anonKey: AppConfig.supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: true,
        ),
      );
      print('Supabase initialized');
      await runSupabaseAuthBootstrap();
    } catch (e, st) {
      debugPrint('Supabase init failed (offline or bad URL): $e');
    }
  }

  runApp(
    const ProviderScope(
      child: SpeedAlertApp(),
    ),
  );
}
