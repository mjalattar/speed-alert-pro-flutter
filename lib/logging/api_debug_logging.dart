import 'package:flutter/foundation.dart';

/// Kotlin [ApiDebugLogging] — logcat-style lines in debug.
class ApiDebugLogging {
  ApiDebugLogging._();

  static void logLine(String tag, String message) {
    if (kDebugMode) {
      debugPrint('[$tag] $message');
    }
  }
}
