import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../providers/driving_session_notifier.dart';
import 'overlay_platform_channel.dart';

/// Registers Dart-side handler for native overlay − / × (same [MethodChannel] name).
void registerOverlayDartHandlers(WidgetRef ref) {
  OverlayPlatformChannel.channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'onMinimize':
        ref.read(preferencesProvider).preferencesManager.isOverlayHudMinimized =
            true;
        ref.read(prefsRevisionProvider.notifier).state++;
        return null;
      case 'onStopMonitoring':
        await ref.read(drivingSessionProvider.notifier).stopTracking();
        return null;
      default:
        throw PlatformException(
          code: 'unimplemented',
          message: 'Unknown overlay method ${call.method}',
        );
    }
  });
}
