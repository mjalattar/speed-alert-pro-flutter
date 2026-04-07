import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import 'preferences_manager.dart';

/// Android system overlay HUD (native code behind [channel] method calls).
class OverlayPlatformChannel {
  OverlayPlatformChannel._();

  static const MethodChannel channel = MethodChannel('speed_alert_pro/overlay');

  static Future<void> hide() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await channel.invokeMethod<void>('hide');
    } on MissingPluginException {
      // ignore
    } catch (_) {}
  }

  static Future<void> sync({
    required PreferencesManager preferencesManager,
    required bool appInForeground,
    required double speedMph,
    required double? limitMph,
    required bool isSpeeding,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (preferencesManager.alertRunMode != AlertRunMode.backgroundOverlay) {
      await hide();
      return;
    }
    if (preferencesManager.isOverlayHudMinimized) {
      await hide();
      return;
    }
    if (appInForeground) {
      await hide();
      return;
    }
    try {
      await channel.invokeMethod<void>('update', <String, dynamic>{
        'speedMph': speedMph,
        'limitMph': limitMph,
        'speeding': isSpeeding,
      });
    } on MissingPluginException {
      // ignore
    } catch (_) {}
  }
}
