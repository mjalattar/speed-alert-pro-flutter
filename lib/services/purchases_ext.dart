import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

/// Kotlin [PurchasesExt] — [IllegalStateException] with `error.message + " (" + error.code + ")"`.
class PurchasesExt {
  PurchasesExt._();

  /// Same string shape as Kotlin [PurchasesError] passed to [IllegalStateException].
  static String kotlinStylePurchasesErrorMessage(Object error) {
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

  /// Kotlin [Purchases.awaitCustomerInfo].
  static Future<CustomerInfo> awaitCustomerInfo() async {
    try {
      return await Purchases.getCustomerInfo();
    } catch (e) {
      throw StateError(kotlinStylePurchasesErrorMessage(e));
    }
  }

  /// Kotlin [Purchases.awaitRestorePurchases].
  static Future<CustomerInfo> awaitRestorePurchases() async {
    try {
      return await Purchases.restorePurchases();
    } catch (e) {
      throw StateError(kotlinStylePurchasesErrorMessage(e));
    }
  }
}
