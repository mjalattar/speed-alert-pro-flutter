import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/speed_alert_application_bootstrap.dart';
import 'app/speed_alert_app.dart';
import 'config/app_config.dart';
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
      );
      await runSupabaseAuthBootstrap();
    } catch (e, st) {
      developer.log(
        'Supabase init failed (offline or bad URL)',
        name: 'SpeedAlertApp',
        error: e,
        stackTrace: st,
      );
    }
  }

  runApp(
    const ProviderScope(
      child: SpeedAlertApp(),
    ),
  );
}
