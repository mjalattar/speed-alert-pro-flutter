import 'dart:developer' as developer;

import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

/// Post–Supabase-init bootstrap: drop anonymous-only sessions and sync RevenueCat when a real session exists.
Future<void> runSupabaseAuthBootstrap() async {
  try {
    await signOutIfAnonymousOnly();
    if (hasGoogleOrNonAnonymousSession()) {
      await syncRevenueCatWithSupabaseUser();
    }
  } catch (e, st) {
    developer.log(
      'Supabase auth init failed',
      name: 'SpeedAlertApp',
      error: e,
      stackTrace: st,
    );
  }
}

/// Signs out if the current user is anonymous-only.
/// Guards against empty identities — a Google-authenticated user may briefly
/// have an empty identities list during session recovery; only sign out if
/// the user is explicitly marked as anonymous by Supabase.
Future<void> signOutIfAnonymousOnly() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return;
  final ids = user.identities ?? [];
  if (ids.isEmpty) return;
  final onlyAnonymous = ids.every((i) => i.provider.trim().toLowerCase() == 'anonymous');
  if (onlyAnonymous) {
    await Supabase.instance.client.auth.signOut();
  }
}

/// True when a session exists with at least one non-anonymous identity.
bool hasGoogleOrNonAnonymousSession() {
  if (Supabase.instance.client.auth.currentSession == null) return false;
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return false;
  final ids = user.identities ?? [];
  if (ids.isEmpty) return false;
  return ids.any((i) => i.provider.trim().toLowerCase() != 'anonymous');
}

/// Associates RevenueCat with the signed-in Supabase user id.
Future<void> syncRevenueCatWithSupabaseUser() async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return;
  if (AppConfig.revenueCatPublicApiKey.isEmpty) return;
  await Purchases.logIn(uid);
}
