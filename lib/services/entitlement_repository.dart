import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../core/entitlement_ids.dart';
import 'preferences_manager.dart';
import 'purchases_ext.dart';

/// Trial window + RevenueCat premium entitlement.
class EntitlementRepository {
  EntitlementRepository._();

  static Future<bool> hasPremiumAccess({
    required PreferencesManager preferencesManager,
    SupabaseClient? supabase,
  }) async {
    if (!AppConfig.useRemoteHere || !preferencesManager.useRemoteSpeedApi) {
      return true;
    }

    final client = supabase ?? Supabase.instance.client;
    final trialEndsIso = await _fetchTrialEndsIso(client);
    if (_trialStillActive(trialEndsIso)) {
      return true;
    }

    if (AppConfig.revenueCatPublicApiKey.isEmpty) {
      return false;
    }

    try {
      final info = await PurchasesExt.awaitCustomerInfo();
      return info.entitlements.all[EntitlementIds.premium]?.isActive == true;
    } catch (e, st) {
      developer.log(
        'RevenueCat customer info',
        name: 'EntitlementRepository',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  static bool _trialStillActive(String? iso) {
    if (iso == null || iso.isEmpty) return false;
    final dt = DateTime.tryParse(iso);
    if (dt == null) return false;
    return dt.isAfter(DateTime.now().toUtc());
  }

  static Future<String?> _fetchTrialEndsIso(SupabaseClient client) async {
    final session = client.auth.currentSession;
    if (session == null) return null;
    final uid = client.auth.currentUser?.id;
    if (uid == null) return null;

    final base = AppConfig.supabaseUrl.trim().replaceAll(RegExp(r'/$'), '');
    final uri = Uri.parse(
      '$base/rest/v1/profiles?id=eq.$uid&select=trial_ends_at',
    );

    try {
      final res = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer ${session.accessToken}',
          'apikey': AppConfig.supabaseAnonKey,
        },
      );
      if (res.statusCode != 200) return null;
      final list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) return null;
      final row = list.first as Map<String, dynamic>;
      final v = row['trial_ends_at'];
      if (v == null) return null;
      return v.toString();
    } catch (_) {
      return null;
    }
  }
}
