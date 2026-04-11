import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../services/auth/auth_check_service.dart';

/// Post–Supabase-init bootstrap: ensure a session exists, sync RevenueCat,
/// and check subscription access — runs in the background after first frame.
Future<void> runSupabaseAuthBootstrap() async {
  try {
    var session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      debugPrint('[AUTH BOOTSTRAP] No session — attempting refreshSession...');
      try {
        final response = await Supabase.instance.client.auth.refreshSession();
        session = response.session;
        debugPrint('[AUTH BOOTSTRAP] refreshSession result: ${session != null ? 'uid=${session.user.id}' : 'null'}');
      } catch (e) {
        debugPrint('[AUTH BOOTSTRAP] refreshSession failed: $e');
      }
    }

    if (session == null) {
      debugPrint('[AUTH BOOTSTRAP] No recoverable session — signing in anonymously...');
      await Supabase.instance.client.auth.signInAnonymously();
      session = Supabase.instance.client.auth.currentSession;
      debugPrint('[AUTH BOOTSTRAP] Anonymous sign-in result: ${session != null ? 'uid=${session.user.id}' : 'null'}');
    } else {
      debugPrint('[AUTH BOOTSTRAP] Existing session: uid=${session.user.id}, isAnonymous=${session.user.isAnonymous}');
    }
  } catch (e, st) {
    debugPrint('Supabase auth bootstrap failed: $e\n$st');
  }

  _backgroundSync();
}

void _backgroundSync() {
  (() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null && AppConfig.revenueCatPublicApiKey.isNotEmpty) {
        await Purchases.logIn(uid);
      }
    } catch (e) {
      debugPrint('[AUTH BOOTSTRAP] RevenueCat sync error: $e');
    }
  })();
}