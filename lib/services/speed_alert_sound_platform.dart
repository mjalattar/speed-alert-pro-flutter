import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import 'preferences_manager.dart';

/// Native debounced speeding beep when alerts are eligible.
class SpeedAlertSoundPlatform {
  SpeedAlertSoundPlatform._();

  static const MethodChannel _ch = MethodChannel('speed_alert_pro/speed_alert_sound');

  static Future<void> playDebouncedIfEligible({
    required PreferencesManager preferencesManager,
    required bool appInForeground,
  }) async {
    if (!preferencesManager.isAudibleAlertEnabled) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    final mode = preferencesManager.alertRunMode;
    final shouldPlay = switch (mode) {
      AlertRunMode.normal => appInForeground,
      AlertRunMode.backgroundSound => true,
      AlertRunMode.backgroundOverlay => true,
      _ => false,
    };
    if (!shouldPlay) return;

    try {
      await _ch.invokeMethod<void>('playDebounced', <String, int>{
        'minIntervalMs': 3000,
        'durationMs': 200,
      });
    } on MissingPluginException {
      return;
    }
  }
}
