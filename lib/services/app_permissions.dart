import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

class AppPermissions {
  AppPermissions._();

  static Future<bool> ensureLocationPermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever ||
        perm == LocationPermission.denied) {
      return false;
    }
    if (perm == LocationPermission.whileInUse) {
      await _requestBackgroundLocation();
    }
    return true;
  }

  static Future<bool> _requestBackgroundLocation() async {
    if (!Platform.isAndroid) return true;

    final status = await ph.Permission.locationAlways.status;
    if (status.isGranted) return true;

    final result = await ph.Permission.locationAlways.request();
    return result.isGranted;
  }

  static Future<bool> isBackgroundLocationGranted() async {
    if (!Platform.isAndroid) return true;
    final status = await ph.Permission.locationAlways.status;
    return status.isGranted;
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