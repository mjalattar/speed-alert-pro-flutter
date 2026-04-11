import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../services/auth/auth_check_service.dart';
import '../services/auth/auth_session_provider.dart';
import '../providers/app_providers.dart';
import '../screens/subscription_paywall_screen.dart';

/// When [AppConfig.useRemoteHere]: always show main content (anonymous or signed-in).
/// The inner [EntitlementGate] checks trial/subscription and shows the paywall if needed.
class AppRootGate extends ConsumerWidget {
  const AppRootGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!AppConfig.useRemoteHere) {
      return child;
    }

    final auth = ref.watch(authSessionProvider);
    debugPrint('[AUTH GATE] auth state: ${auth.when(loading: () => 'LOADING', error: (e, st) => 'ERROR: $e', data: (s) => s != null ? 'uid=${s.user.id} anon=${s.user.isAnonymous}' : 'session=null')}');

    return auth.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, st) => Scaffold(
        body: Center(child: Text('Auth error: $e')),
      ),
      data: (session) {
        // Both anonymous and signed-in users reach the main content.
        // The EntitlementGate handles subscription/trial checks.
        // No session at all = still initializing; bootstrap will create anonymous.
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
    if (!AppConfig.useRemoteHere) {
      return child;
    }

    final access = ref.watch(entitlementAccessProvider);
    debugPrint('[ENTITLEMENT GATE] access=$access');
    return access.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, st) => Scaffold(
        body: Center(child: Text('$e')),
      ),
      data: (ok) {
        debugPrint('[ENTITLEMENT GATE] ok=$ok, showing ${ok ? 'main' : 'paywall'}');
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