// PROJECT_STATUS: 100% VERIFIED_MIRROR
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

/// Kotlin [SpeedAlertApplication.onCreate] order:
/// 1. [Application.onCreate] / [instance] (Flutter: binding + prefs).
/// 2. [Purchases.configure] when [BuildConfig.REVENUECAT_PUBLIC_API_KEY] non-blank.
/// 3. When [BuildConfig.USE_REMOTE_HERE]: [SupabaseManager.create], [HereEdgeFunctionClient],
///    then `runBlocking(Dispatchers.IO)` { [awaitAuthReady], [signOutIfAnonymousOnly],
///    optional [syncRevenueCatWithSupabaseUser] }.
///
/// **Location pipeline** ([SpeedAlertService.onCreate] / [LocationProcessor]) starts only when the user
/// begins driving tracking — not here (see [DrivingSessionNotifier.startTracking]).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SpeedAlertLogFilesystem.init();

  PreferencesManager.registerAndroidKotlinPrefsParityBeforeOpen();
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
      await runSupabaseAuthBootstrapLikeKotlin();
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
