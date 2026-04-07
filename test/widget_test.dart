import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speed_alert_pro/providers/app_providers.dart';
import 'package:speed_alert_pro/screens/home_screen.dart';
import 'package:speed_alert_pro/services/preferences_manager.dart';

void main() {
  testWidgets('Driving screen title visible', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final preferencesManager = await PreferencesManager.open();
    initializePreferences(preferencesManager);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: const HomeScreen(),
        ),
      ),
    );
    expect(find.text('Location tracking'), findsOneWidget);
  });
}
