import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android overlay permission: 1×1 prime window + OEM “display over other apps” settings intents.
class OverlayPermissionPlatform {
  OverlayPermissionPlatform._();

  static const MethodChannel _ch =
      MethodChannel('speed_alert_pro/overlay_permission');

  /// Prime overlay permission and open system overlay settings when needed.
  static Future<void> primeAttemptAndOpenManageScreen() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('primeAttemptAndOpenManageScreen');
    } on MissingPluginException {
      return;
    }
  }

  /// Open system overlay permission settings.
  static Future<void> openManageOverlayScreen() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('openManageOverlayScreen');
    } on MissingPluginException {
      return;
    }
  }
}
