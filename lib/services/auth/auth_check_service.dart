import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/app_config.dart';

class AuthCheckResult {
  final String userId;
  final bool accessAllowed;
  final bool trialActive;
  final bool subscriptionActive;

  AuthCheckResult({
    required this.userId,
    required this.accessAllowed,
    required this.trialActive,
    required this.subscriptionActive,
  });

  factory AuthCheckResult.fromJson(Map<String, dynamic> json) {
    return AuthCheckResult(
      userId: json['user_id'] as String? ?? '',
      accessAllowed: json['access_allowed'] as bool? ?? false,
      trialActive: json['trial_active'] as bool? ?? false,
      subscriptionActive: json['subscription_active'] as bool? ?? false,
    );
  }
}

class AuthCheckService {
  AuthCheckService._();

  static AuthCheckResult? _lastResult;

  static AuthCheckResult? get lastResult => _lastResult;

  static Future<AuthCheckResult?> checkAccess() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return null;
    if (!AppConfig.useRemoteHere) return null;

    final baseUrl = AppConfig.supabaseUrl.trim().replaceAll(RegExp(r'/$'), '');
    final uri = Uri.parse('$baseUrl/functions/v1/auth-check');

    try {
      final res = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${session.accessToken}',
          'apikey': AppConfig.supabaseAnonKey,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: '{}',
      );

      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        debugPrint('[AUTH-CHECK] result: access_allowed=${json['access_allowed']}, trial=${json['trial_active']}, sub=${json['subscription_active']}');
        final result = AuthCheckResult.fromJson(json);
        _lastResult = result;
        return result;
      }

      debugPrint('[AUTH-CHECK] HTTP ${res.statusCode}: ${res.body}');
      return null;
    } catch (e) {
      debugPrint('[AUTH-CHECK] error: $e');
      return null;
    }
  }
}