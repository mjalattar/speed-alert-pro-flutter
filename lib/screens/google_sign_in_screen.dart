import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../services/google_auth_service.dart';

/// Google sign-in entry screen for remote HERE / Supabase.
class GoogleSignInScreen extends StatefulWidget {
  const GoogleSignInScreen({super.key});

  @override
  State<GoogleSignInScreen> createState() => _GoogleSignInScreenState();
}

class _GoogleSignInScreenState extends State<GoogleSignInScreen> {
  bool _loading = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await GoogleAuthService.signInWithGoogle();
    } catch (e) {
      if (GoogleAuthService.isUserCancellation(e)) {
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _error = GoogleAuthService.userFacingMessage(e);
        _loading = false;
      });
      return;
    }
    if (mounted) setState(() => _loading = false);
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
                'Speed Alert Pro',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              Text(
                'Sign in with Google to continue (required for cloud speed limits and trial).',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              if (AppConfig.googleWebClientId.isEmpty)
                Text(
                  'Missing OAuth Web Client ID. Add GOOGLE_WEB_CLIENT_ID via --dart-define '
                  '(see supabase/SETUP.txt), then rebuild.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else ...[
                if (_error != null)
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                FilledButton(
                  onPressed: _loading ? null : _signIn,
                  child: _loading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sign in with Google'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
