import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'speed_debug_log_session.dart';

/// App log directory — mirrors Kotlin `Context.getExternalFilesDir(null) ?: filesDir`.
class SpeedAlertLogFilesystem {
  SpeedAlertLogFilesystem._();

  static Directory? _root;

  static Directory get root {
    final r = _root;
    if (r == null) {
      throw StateError('SpeedAlertLogFilesystem.init() was not called');
    }
    return r;
  }

  static Future<void> init() async {
    if (_root != null) return;
    final ext = await getExternalStorageDirectory();
    _root = ext ?? await getApplicationSupportDirectory();
  }

  /// Kotlin [SpeedLimitApiRequestLogger.unifiedLogStorageFileName]
  static String unifiedLogStorageFileName(SpeedDebugLogSession session) {
    switch (session) {
      case SpeedDebugLogSession.simulation:
        return 'speed_limit_log_simulation.csv';
      case SpeedDebugLogSession.driving:
        return 'speed_limit_log_driving.csv';
      case SpeedDebugLogSession.none:
        throw StateError('invalid session');
    }
  }

  static File sessionLogFile(SpeedDebugLogSession session) {
    return File('${root.path}/${unifiedLogStorageFileName(session)}');
  }
}
