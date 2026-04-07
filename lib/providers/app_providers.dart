import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../core/app_foreground_tracker.dart';
import '../services/speed_providers/mapbox_speed_provider.dart';
import '../services/speed_providers/tomtom_speed_provider.dart';
import '../services/here/here_alert_route_provider.dart';
import '../services/here_api_service.dart';
import '../services/here_edge_function_client.dart';
import '../services/preferences_manager.dart';
import '../services/entitlement_repository.dart';
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

final hereEdgeFunctionClientProvider = Provider<HereEdgeFunctionClient?>((ref) {
  if (!AppConfig.useRemoteHere) return null;
  return HereEdgeFunctionClient(
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

/// HERE Routing / Edge — alert limit and map surfaces only (no TomTom/Mapbox).
final hereAlertRouteProviderProvider = Provider<HereAlertRouteProvider>((ref) {
  return HereAlertRouteProvider(
    preferencesManager: ref.watch(preferencesProvider).preferencesManager,
    hereApi: ref.watch(hereApiServiceProvider),
    hereEdgeFunctionClient: ref.watch(hereEdgeFunctionClientProvider),
  );
});

/// HERE alert + progressive speed rows (Edge or local REST).
final speedLimitAggregatorProvider = Provider<SpeedLimitAggregator>((ref) {
  return SpeedLimitAggregator(
    preferencesManager: ref.watch(preferencesProvider).preferencesManager,
    here: ref.watch(hereAlertRouteProviderProvider),
    tomTom: ref.watch(tomTomSpeedProviderProvider),
    mapbox: ref.watch(mapboxSpeedProviderProvider),
  );
});

final authSessionProvider = StreamProvider<Session?>((ref) async* {
  final client = Supabase.instance.client;
  yield client.auth.currentSession;
  await for (final e in client.auth.onAuthStateChange) {
    yield e.session;
  }
});

final entitlementAccessProvider = FutureProvider.autoDispose<bool>((ref) async {
  final snap = ref.watch(preferencesProvider);
  return EntitlementRepository.hasPremiumAccess(
    preferencesManager: snap.preferencesManager,
  );
});
