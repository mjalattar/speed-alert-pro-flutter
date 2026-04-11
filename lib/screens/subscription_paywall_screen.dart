import 'package:flutter/material.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../core/entitlement_ids.dart';
import '../services/auth/auth_check_service.dart';
import '../services/google_auth_service.dart';
import '../services/purchases_ext.dart';

/// RevenueCat subscription / restore UI for premium unlock.
/// If the user is anonymous, they must sign in with Google first.
class SubscriptionPaywallScreen extends StatefulWidget {
  const SubscriptionPaywallScreen({
    super.key,
    required this.onUnlocked,
  });

  final VoidCallback onUnlocked;

  @override
  State<SubscriptionPaywallScreen> createState() =>
      _SubscriptionPaywallScreenState();
}

class _SubscriptionPaywallScreenState extends State<SubscriptionPaywallScreen> {
  bool _busy = false;
  bool _signingIn = false;
  String? _error;

  bool get _isAnonymous =>
      Supabase.instance.client.auth.currentUser?.isAnonymous ?? false;

  static bool _isUserCancelledPurchase(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('cancel') || s.contains('usercancelled');
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _signingIn = true;
      _error = null;
    });
    try {
      await GoogleAuthService.signInWithGoogle();
      // After linking/signing in, refresh access check
      await AuthCheckService.checkAccess();
      if (mounted) {
        setState(() => _signingIn = false);
        // Re-check entitlement
        widget.onUnlocked();
      }
    } catch (e) {
      if (GoogleAuthService.isUserCancellation(e)) {
        if (mounted) setState(() => _signingIn = false);
        return;
      }
      if (mounted) {
        setState(() {
          _error = GoogleAuthService.userFacingMessage(e);
          _signingIn = false;
        });
      }
    }
  }

  Future<void> _subscribe() async {
    // If anonymous, sign in with Google first
    if (_isAnonymous) {
      await _signInWithGoogle();
      // After sign-in, the entitlement check will re-evaluate.
      // If sign-in succeeded, onUnlocked was already called.
      return;
    }

    if (AppConfig.revenueCatPublicApiKey.isEmpty) {
      setState(() => _error = 'RevenueCat is not configured (REVENUECAT_PUBLIC_API_KEY).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final offerings = await Purchases.getOfferings();
      final pkgs = offerings.current?.availablePackages;
      final pkg = (pkgs != null && pkgs.isNotEmpty) ? pkgs.first : null;
      if (pkg == null) {
        setState(() {
          _busy = false;
          _error =
              'No subscription packages in RevenueCat. Check the dashboard and store products.';
        });
        return;
      }
      final info = await Purchases.purchasePackage(pkg);
      // RevenueCat may need a moment to activate the entitlement after Google Play confirms.
      // Retry a few times with a short delay.
      EntitlementInfo? premium;
      for (int i = 0; i < 5; i++) {
        premium = info.entitlements.all[EntitlementIds.premium];
        if (premium?.isActive == true) break;
        await Future.delayed(const Duration(seconds: 1));
        try {
          final refreshed = await Purchases.getCustomerInfo();
          premium = refreshed.entitlements.all[EntitlementIds.premium];
          if (premium?.isActive == true) break;
        } catch (_) {}
      }
      if (premium?.isActive == true) {
        await AuthCheckService.checkAccess();
        widget.onUnlocked();
      } else {
        setState(() {
          _busy = false;
          _error = 'Purchase recorded. Please close and reopen the app to activate.';
        });
      }
    } catch (e) {
      if (_isUserCancelledPurchase(e)) {
        setState(() => _busy = false);
        return;
      }
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
    if (mounted && _busy) setState(() => _busy = false);
  }

  Future<void> _restore() async {
    if (AppConfig.revenueCatPublicApiKey.isEmpty) {
      setState(() => _error = 'RevenueCat is not configured.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final info = await PurchasesExt.awaitRestorePurchases();
      // Retry checking entitlement activation a few times after restore
      EntitlementInfo? premium = info.entitlements.all[EntitlementIds.premium];
      for (int i = 0; i < 5; i++) {
        if (premium?.isActive == true) break;
        await Future.delayed(const Duration(seconds: 1));
        try {
          final refreshed = await Purchases.getCustomerInfo();
          premium = refreshed.entitlements.all[EntitlementIds.premium];
          if (premium?.isActive == true) break;
        } catch (_) {}
      }
      if (premium?.isActive == true) {
        await AuthCheckService.checkAccess();
        widget.onUnlocked();
      } else {
        await AuthCheckService.checkAccess();
        setState(() {
          _busy = false;
          _error = 'No active subscription found. If you just purchased, please close and reopen the app in a few minutes.';
        });
      }
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e is StateError
            ? e.message
            : (e is Exception ? e.toString() : '$e');
      });
    }
    if (mounted && _busy) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Subscribe to continue',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                _isAnonymous
                    ? 'Your free trial has ended. Sign in with Google and subscribe to continue using cloud speed limits.'
                    : 'Your free trial has ended. Subscribe to continue using cloud speed limits.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              if (_busy || _signingIn)
                const Center(child: CircularProgressIndicator())
              else ...[
                FilledButton(
                  onPressed: _subscribe,
                  child: Text(_isAnonymous ? 'Sign in & Subscribe' : 'Subscribe'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _restore,
                  child: const Text('Restore purchases'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}