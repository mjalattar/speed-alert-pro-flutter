import 'dart:async';

import 'package:http/http.dart' as http;

import '../services/preferences_manager.dart';
import 'speed_provider_http_session_logger.dart';
import 'logging_globals.dart';
import 'speed_limit_api_request_logger.dart';
import 'speed_limit_api_session_counter.dart';

/// Wraps HTTP GET/POST for speed-related APIs and records bodies when logging is enabled.
class SpeedLimitHttpLogInterceptor {
  SpeedLimitHttpLogInterceptor._();

  static bool _skipDiscover(Uri uri) {
    return uri.host.toLowerCase().contains('discover.search.hereapi.com');
  }

  static Future<http.Response> get(
    Uri uri, {
    required String category,
    Map<String, String>? headers,
    String requestReasonHuman = '',
    bool countTowardSession = true,
  }) async {
    if (_skipDiscover(uri)) {
      return http.get(uri, headers: headers ?? const {});
    }
    final prefs = speedAlertLoggingPreferences;
    final urlRedacted = SpeedLimitApiRequestLogger.redactUrl(uri.toString());
    try {
      final response = await http.get(uri, headers: headers ?? const {});
      if (countTowardSession) {
        SpeedLimitApiSessionCounter.recordIfSessionActive();
        if (category == 'HERE_Routing') {
          SpeedLimitApiSessionCounter.recordHereRoutingIfActive();
        }
      }
      _append(prefs, category, 'GET', urlRedacted, response.statusCode, '');
      return response;
    } catch (e) {
      if (countTowardSession) {
        SpeedLimitApiSessionCounter.recordIfSessionActive();
        if (category == 'HERE_Routing') {
          SpeedLimitApiSessionCounter.recordHereRoutingIfActive();
        }
      }
      _append(prefs, category, 'GET', urlRedacted, -1, 'io:$e');
      rethrow;
    }
  }

  static Future<http.Response> post(
    Uri uri, {
    required Map<String, String> headers,
    Object? body,
    required String category,
    String requestReasonHuman = '',
    bool countTowardSession = true,
  }) async {
    final prefs = speedAlertLoggingPreferences;
    final urlRedacted = SpeedLimitApiRequestLogger.redactUrl(uri.toString());
    try {
      final response = await http.post(uri, headers: headers, body: body);
      if (countTowardSession) {
        SpeedLimitApiSessionCounter.recordIfSessionActive();
        if (category == 'HERE_Routing') {
          SpeedLimitApiSessionCounter.recordHereRoutingIfActive();
        }
      }
      _append(prefs, category, 'POST', urlRedacted, response.statusCode, '');
      return response;
    } catch (e) {
      if (countTowardSession) {
        SpeedLimitApiSessionCounter.recordIfSessionActive();
        if (category == 'HERE_Routing') {
          SpeedLimitApiSessionCounter.recordHereRoutingIfActive();
        }
      }
      _append(prefs, category, 'POST', urlRedacted, -1, 'io:$e');
      rethrow;
    }
  }

  static void _append(
    PreferencesManager? prefs,
    String category,
    String method,
    String urlRedacted,
    int httpCode,
    String note,
  ) {
    if (prefs == null) return;
    SpeedProviderHttpSessionLogger.recordIfApplicable(
      preferencesManager: prefs,
      category: category,
      method: method,
      urlRedacted: urlRedacted,
      httpCode: httpCode,
      note: note,
    );
    unawaited(
      SpeedLimitApiRequestLogger.appendIfEnabled(
        preferencesManager: prefs,
        category: category,
        method: method,
        urlRedacted: urlRedacted,
        httpCode: httpCode,
        note: note,
      ),
    );
  }
}
