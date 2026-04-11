import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../core/app_foreground_tracker.dart';
import '../core/constants.dart' show SpeedLimitPrimaryProvider;
import '../services/auth/auth_check_service.dart';
import '../services/auth/auth_session_provider.dart';
import '../services/mapbox/speed_provider.dart';
import '../services/tomtom/speed_provider.dart';
import '../services/here/api_service.dart';
import '../services/here/here_alert_route_provider.dart';
import '../services/remote/edge_function_client.dart';
import '../services/remote/remote_alert_route_provider.dart';
import '../services/preferences_manager.dart';
import '../services/speed_limit_aggregator.dart';

PreferencesManager? _globalPrefs;

void initializePreferences(PreferencesManager preferencesManager) {
  _globalPrefs = preferencesManager;
}

/// Bump with `ref.read(prefsRevisionProvider.notifier).state++` after mutating [PreferencesManager].
final prefsRevisionProvider = StateProvider<int>((ref) => 0);

/// [PreferencesManager] plus a changing [revision] so Riverpod notifies after SharedPreferences writes.
typedef PrefsSnapshot = ({int revision, PreferencesManager preferencesManager});

/// Main shell visibility for alert gating — `false` at init; then follows [DrivingSessionNotifier.syncAppLifecycle]:
/// `resumed` → true; `paused`/`hidden`/`detached` → false; `inactive` does not toggle.
/// See [AppForegroundTracker].
final appForegroundVisibleProvider = StateProvider<bool>((ref) {
  return AppForegroundTracker.isMainActivityVisible;
});

final preferencesProvider = Provider<PrefsSnapshot>((ref) {
  final revision = ref.watch(prefsRevisionProvider);
  final p = _globalPrefs;
  if (p == null) {
    throw StateError('initializePreferences() was not called before runApp');
  }
  return (revision: revision, preferencesManager: p);
});

/// Single shared [HereApiService] for local HERE routing / discover.
final hereApiServiceProvider = Provider<HereApiService>(
  (ref) => HereApiService.create(apiKey: AppConfig.hereApiKey),
);

final remoteEdgeFunctionClientProvider = Provider<RemoteEdgeFunctionClient?>((ref) {
  if (!AppConfig.useRemoteHere) return null;
  return RemoteEdgeFunctionClient(
    accessTokenProvider: () async {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) {
        throw StateError('Not signed in');
      }
      return session.accessToken;
    },
  );
});

/// TomTom Snap sticky cache + HTTP (independent of HERE and Mapbox).
final tomTomSpeedProviderProvider = Provider<TomTomSpeedProvider>((ref) {
  return TomTomSpeedProvider(
    preferencesManager: ref.watch(preferencesProvider).preferencesManager,
  );
});

/// Mapbox Directions sticky cache + HTTP (independent of HERE and TomTom).
final mapboxSpeedProviderProvider = Provider<MapboxSpeedProvider>((ref) {
  return MapboxSpeedProvider(
    preferencesManager: ref.watch(preferencesProvider).preferencesManager,
  );
});

/// HERE Router on device (no Remote).
final hereAlertRouteProviderProvider = Provider<HereAlertRouteProvider>((ref) {
  return HereAlertRouteProvider(
    preferencesManager: ref.watch(preferencesProvider).preferencesManager,
    hereApi: ref.watch(hereApiServiceProvider),
  );
});

/// Remote (Supabase Edge) — separate from HERE REST.
final remoteAlertRouteProviderProvider = Provider<RemoteAlertRouteProvider>((ref) {
  return RemoteAlertRouteProvider(
    preferencesManager: ref.watch(preferencesProvider).preferencesManager,
    edgeClient: ref.watch(remoteEdgeFunctionClientProvider),
  );
});

/// HERE, Remote, TomTom, Mapbox rows for progressive UI; primary matches [LocationProcessor].
final speedLimitAggregatorProvider = Provider<SpeedLimitAggregator>((ref) {
  return SpeedLimitAggregator(
    preferencesManager: ref.watch(preferencesProvider).preferencesManager,
    here: ref.watch(hereAlertRouteProviderProvider),
    remote: ref.watch(remoteAlertRouteProviderProvider),
    tomTom: ref.watch(tomTomSpeedProviderProvider),
    mapbox: ref.watch(mapboxSpeedProviderProvider),
  );
});

/// Server-side access check via auth-check edge function.
/// Applies to the entire app regardless of which speed limit provider is selected.
final entitlementAccessProvider = FutureProvider.autoDispose<bool>((ref) async {
  if (!AppConfig.useRemoteHere) {
    return true;
  }

  // Always call the edge function fresh for authoritative access decision.
  final result = await AuthCheckService.checkAccess();
  if (result != null) {
    return result.accessAllowed;
  }

  // If auth-check failed (offline), allow access to avoid blocking the user.
  return true;
});
