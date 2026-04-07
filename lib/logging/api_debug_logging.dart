import 'package:flutter/foundation.dart';

/// Debug-only tagged lines to the console.
class ApiDebugLogging {
  ApiDebugLogging._();

  static void logLine(String tag, String message) {
    if (kDebugMode) {
      debugPrint('[$tag] $message');
    }
  }
}
