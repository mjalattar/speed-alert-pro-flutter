import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../core/constants.dart' show SpeedLimitPrimaryProvider;
import '../providers/app_providers.dart';
import '../screens/google_sign_in_screen.dart';
import '../screens/subscription_paywall_screen.dart';

/// When [AppConfig.useRemoteHere]: Google sign-in (outer) then trial / RevenueCat paywall (inner).
class AppRootGate extends ConsumerWidget {
  const AppRootGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!AppConfig.useRemoteHere) {
      return child;
    }

    // Listen for session changes to update RevenueCat
    ref.listen<AsyncValue<Session?>>(authSessionProvider, (prev, next) async {
      print('AppRootGate listen: prev=$prev, next=$next');
      next.whenData((session) async {
        print('AppRootGate listen data: session=$session');
        if (session != null && AppConfig.revenueCatPublicApiKey.isNotEmpty) {
          try {
            await Purchases.logIn(session.user.id);
          } catch (_) {}
        }
      });
    });

    final auth = ref.watch(authSessionProvider);
    print('AppRootGate build: auth=$auth');
    return auth.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, st) => Scaffold(
        body: Center(child: Text('Auth error: $e')),
      ),
      data: (session) {
        print('AppRootGate data: session=${session?.user.id ?? "null"}');
        if (session == null) {
          return const GoogleSignInScreen();
        }
        return EntitlementGate(child: child);
      },
    );
  }
}

class EntitlementGate extends ConsumerWidget {
  const EntitlementGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferencesManager =
        ref.watch(preferencesProvider).preferencesManager;
    final primary = preferencesManager.resolvedPrimarySpeedLimitProvider;
    if (!AppConfig.useRemoteHere ||
        !preferencesManager.isRemoteApiEnabled ||
        primary != SpeedLimitPrimaryProvider.remote) {
      return child;
    }

    final access = ref.watch(entitlementAccessProvider);
    return access.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, st) => Scaffold(
        body: Center(child: Text('$e')),
      ),
      data: (ok) {
        if (!ok) {
          return SubscriptionPaywallScreen(
            onUnlocked: () =>
                ref.invalidate(entitlementAccessProvider),
          );
        }
        return child;
      },
    );
  }
}
