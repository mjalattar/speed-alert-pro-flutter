import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Android overlay permission: 1x1 prime window + OEM "display over other apps" settings intents.
class OverlayPermissionPlatform {
  OverlayPermissionPlatform._();

  static const MethodChannel _ch =
      MethodChannel('speed_alert_pro/overlay_permission');

  /// Returns true if the "display over other apps" permission is already granted.
  static Future<bool> isOverlayPermissionGranted() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    return await ph.Permission.systemAlertWindow.status.isGranted;
  }

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