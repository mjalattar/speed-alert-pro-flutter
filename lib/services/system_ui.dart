import 'package:flutter/services.dart';

class SystemUi {
  SystemUi._();

  static const _channel = MethodChannel('speed_alert_pro/system_ui');

  /// Moves the app to the background (like pressing the home button).
  /// Unlike [SystemNavigator.pop], this does NOT destroy the Activity.
  static Future<void> moveTaskToBack() async {
    await _channel.invokeMethod<void>('moveTaskToBack');
  }
}