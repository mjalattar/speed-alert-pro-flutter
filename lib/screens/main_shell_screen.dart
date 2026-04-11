import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../providers/driving_session_notifier.dart';
import 'home_screen.dart';

class MainShellScreen extends ConsumerStatefulWidget {
  const MainShellScreen({super.key});

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(drivingSessionProvider.notifier).syncAppLifecycle(state);
    if (state == AppLifecycleState.resumed) {
      ref.read(preferencesProvider).preferencesManager.isOverlayHudMinimized =
          false;
      ref.read(prefsRevisionProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(drivingSessionProvider);
    return const HomeScreen();
  }
}
