import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'app_permissions.dart';

class PermissionRequest {
  PermissionRequest._();

  /// Returns:
  /// - `true`  → all location + battery permissions handled (granted or skipped)
  /// - `false` → location permission was denied (cannot proceed)
  static Future<bool> requestBackgroundPermissions(BuildContext context) async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      if (!context.mounted) return false;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Location Access'),
          content: const Text(
            'Speed Alert Pro needs location access to monitor your speed while driving.\n\n'
            'Please select "Allow while using the app".',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Continue')),
          ],
        ),
      );
      if (proceed != true) return false;
      final result = await AppPermissions.ensureLocationPermission();
      if (!result) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission is required')),
          );
        }
        return false;
      }
    }

    final batteryExempt = await AppPermissions.isBatteryOptimizationExempt();
    if (!batteryExempt) {
      if (!context.mounted) return true;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Unrestricted Battery'),
          content: const Text(
            'For reliable background alerts, allow Speed Alert Pro to run without battery restrictions.\n\n'
            'On the next screen, select "Allow".',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Continue')),
          ],
        ),
      );
      if (proceed == true) {
        await AppPermissions.requestBatteryOptimizationExemption();
      }
    }

    return true;
  }
}