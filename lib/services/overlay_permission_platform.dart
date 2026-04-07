import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Kotlin [com.speedalertpro.OverlayPermission] — 1×1 overlay prime + OEM overlay settings intents.
class OverlayPermissionPlatform {
  OverlayPermissionPlatform._();

  static const MethodChannel _ch =
      MethodChannel('speed_alert_pro/overlay_permission');

  /// Kotlin [OverlayPermission.primeAttemptAndOpenManageScreen].
  static Future<void> primeAttemptAndOpenManageScreen() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('primeAttemptAndOpenManageScreen');
    } on MissingPluginException {
      return;
    }
  }

  /// Kotlin [OverlayPermission.openManageOverlayScreen].
  static Future<void> openManageOverlayScreen() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('openManageOverlayScreen');
    } on MissingPluginException {
      return;
    }
  }
}
