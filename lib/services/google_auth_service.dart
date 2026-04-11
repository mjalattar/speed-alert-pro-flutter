import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:gotrue/gotrue.dart' show OAuthProvider;
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

/// Google Sign-In → Supabase identity link (or sign-in) → optional RevenueCat [logIn].
///
/// If the user has an anonymous Supabase session, this links the Google identity
/// to it so the account upgrades in-place. If no anonymous session exists, it
/// creates a new authenticated session.
class GoogleAuthService {
  GoogleAuthService._();

  static Future<void> signInWithGoogle() async {
    final webClientId = AppConfig.googleWebClientId.trim();
    if (webClientId.isEmpty) {
      throw StateError(
        'Missing GOOGLE_WEB_CLIENT_ID. Pass --dart-define=GOOGLE_WEB_CLIENT_ID=...',
      );
    }

    final googleSignIn = GoogleSignIn(
      scopes: const ['email', 'profile'],
      serverClientId: webClientId,
    );

    final account = await googleSignIn.signIn();
    if (account == null) {
      throw StateError('SIGN_IN_CANCELLED');
    }

    final auth = await account.authentication;
    final idToken = auth.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw StateError('No Google ID token');
    }

    final client = Supabase.instance.client;
    final currentUser = client.auth.currentUser;
    final isAnonymous = currentUser?.isAnonymous ?? false;

    if (isAnonymous) {
      // Link Google identity to the existing anonymous account
      debugPrint('[AUTH] Linking Google identity to anonymous account...');
      await client.auth.linkIdentityWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );
      debugPrint('[AUTH] Google identity linked successfully');
    } else {
      // No anonymous session — sign in with Google
      await client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );
    }

    final uid = client.auth.currentUser?.id;
    if (uid != null && AppConfig.revenueCatPublicApiKey.isNotEmpty) {
      await Purchases.logIn(uid);
    }
  }

  static bool isUserCancellation(Object e) {
    final s = e.toString();
    return s.contains('SIGN_IN_CANCELLED') ||
        s.contains('sign_in_canceled') ||
        s.contains('SignInException');
  }

  /// Maps plugin / platform errors to a short hint for OAuth misconfiguration.
  static String userFacingMessage(Object e) {
    if (e is StateError) return e.message;
    if (e is PlatformException) {
      final msg = e.message ?? '';
      // Android ApiException 10 = DEVELOPER_ERROR (package/SHA-1 vs Android OAuth client).
      if (e.code == 'sign_in_failed' &&
          (msg.contains(': 10') ||
              msg.contains('10:') ||
              msg.contains('DEVELOPER_ERROR'))) {
        return 'Google could not verify this app build (DEVELOPER_ERROR). '
            'In Google Cloud Console, open the Android OAuth client for '
            'com.example.speed_alert_pro and ensure the SHA-1 matches the keystore used for this APK '
            '(run `cd android && .\\gradlew signingReport`).';
      }
    }
    return '$e';
  }
}
