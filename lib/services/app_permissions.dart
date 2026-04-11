import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

class AppPermissions {
  AppPermissions._();

  /// Ensures we have location permission (at least "while in use").
  /// On modern Android, "while in use" is sufficient for background/overlay modes.
  static Future<bool> ensureLocationPermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever ||
        perm == LocationPermission.denied) {
      return false;
    }
    // Accept both "whileInUse" and "always" as sufficient
    return perm == LocationPermission.whileInUse ||
        perm == LocationPermission.always;
  }

  static Future<bool> isBatteryOptimizationExempt() async {
    if (!Platform.isAndroid) return true;
    final status = await ph.Permission.ignoreBatteryOptimizations.status;
    return status.isGranted;
  }

  static Future<bool> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return true;
    final status = await ph.Permission.ignoreBatteryOptimizations.request();
    return status.isGranted;
  }

  static Future<void> openSettings() async {
    await ph.openAppSettings();
  }
}
