import 'package:flutter/material.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../config/app_config.dart';
import '../core/entitlement_ids.dart';
import '../services/purchases_ext.dart';

/// RevenueCat subscription / restore UI for premium unlock.
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
  String? _error;

  static bool _isUserCancelledPurchase(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('cancel') || s.contains('usercancelled');
  }

  Future<void> _subscribe() async {
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
      if (info.entitlements.all[EntitlementIds.premium]?.isActive == true) {
        widget.onUnlocked();
      } else {
        setState(() {
          _busy = false;
          _error =
              'Purchase completed but premium entitlement is not active yet.';
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
      if (info.entitlements.all[EntitlementIds.premium]?.isActive == true) {
        widget.onUnlocked();
      } else {
        setState(() {
          _busy = false;
          _error = 'No active subscription found.';
        });
      }
    } catch (e) {
      setState(() {
        _busy = false;
        // [PurchasesExt] surfaces failures as [StateError] with a short message.
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
                'Speed limits are fetched securely from our servers. Your free trial has ended, or a subscription is required.',
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
              if (_busy)
                const Center(child: CircularProgressIndicator())
              else ...[
                FilledButton(
                  onPressed: _subscribe,
                  child: const Text('Subscribe'),
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
