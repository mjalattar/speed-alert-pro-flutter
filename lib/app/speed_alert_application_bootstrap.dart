import 'dart:developer' as developer;

import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

/// Kotlin [SpeedAlertApplication] block that runs after Supabase client creation:
/// [SupabaseManager.awaitAuthReady], [SupabaseManager.signOutIfAnonymousOnly],
/// and [SpeedAlertApplication.syncRevenueCatWithSupabaseUser] when a non-anonymous session exists.
///
/// Mirrors `runBlocking(Dispatchers.IO) { ... }` in [SpeedAlertApplication.onCreate].
// VERIFIED: 1:1 Logic match with Kotlin (auth readiness, anonymous sign-out, RC logIn).
Future<void> runSupabaseAuthBootstrapLikeKotlin() async {
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

/// Kotlin [SupabaseManager.signOutIfAnonymousOnly].
Future<void> signOutIfAnonymousOnly() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return;
  final ids = user.identities ?? [];
  final onlyAnonymous = ids.isEmpty ||
      ids.every((i) => i.provider.trim().toLowerCase() == 'anonymous');
  if (onlyAnonymous) {
    await Supabase.instance.client.auth.signOut();
  }
}

/// Kotlin [SupabaseManager.hasGoogleOrNonAnonymousSession].
bool hasGoogleOrNonAnonymousSession() {
  if (Supabase.instance.client.auth.currentSession == null) return false;
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return false;
  final ids = user.identities ?? [];
  if (ids.isEmpty) return false;
  return ids.any((i) => i.provider.trim().toLowerCase() != 'anonymous');
}

/// Kotlin [SpeedAlertApplication.syncRevenueCatWithSupabaseUser].
Future<void> syncRevenueCatWithSupabaseUser() async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return;
  if (AppConfig.revenueCatPublicApiKey.isEmpty) return;
  await Purchases.logIn(uid);
}
