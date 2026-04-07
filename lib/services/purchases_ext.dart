import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

/// Helpers around [purchases_flutter] with consistent [StateError] messages.
class PurchasesExt {
  PurchasesExt._();

  /// Builds `message (code)` from [PlatformException] or common plugin error shapes.
  static String formatPurchasesErrorMessage(Object error) {
    if (error is PlatformException) {
      final m = error.message ?? '';
      final c = error.code;
      return '$m ($c)';
    }
    try {
      final dynamic d = error;
      final m = d.message as String?;
      final c = d.code;
      if (m != null && c != null) {
        return '$m ($c)';
      }
    } catch (_) {}
    return error.toString();
  }

  /// [Purchases.getCustomerInfo] wrapped to throw [StateError] on failure.
  static Future<CustomerInfo> awaitCustomerInfo() async {
    try {
      return await Purchases.getCustomerInfo();
    } catch (e) {
      throw StateError(formatPurchasesErrorMessage(e));
    }
  }

  /// [Purchases.restorePurchases] wrapped to throw [StateError] on failure.
  static Future<CustomerInfo> awaitRestorePurchases() async {
    try {
      return await Purchases.restorePurchases();
    } catch (e) {
      throw StateError(formatPurchasesErrorMessage(e));
    }
  }
}
