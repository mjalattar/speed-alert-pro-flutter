import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../providers/driving_session_notifier.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'testing_screen.dart';

/// Root shell: tab **0 = Testing**, **1 = Driving**.
/// Leaving **Driving** for Testing stops tracking; simulation can continue while you view Driving.
class MainShellScreen extends ConsumerStatefulWidget {
  const MainShellScreen({super.key});

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen>
    with WidgetsBindingObserver {
  /// Default **0** — Testing tab first.
  var _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        ref
            .read(drivingSessionProvider.notifier)
            .restoreAndroidFusedSessionIfNeeded(),
      );
    });
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
    final notifier = ref.read(drivingSessionProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(_index == 0 ? 'Testing Mode' : 'Speed Alert Pro'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          TestingScreen(tabActive: _index == 0),
          HomeScreen(tabActive: _index == 1),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          final prev = _index;
          setState(() => _index = i);
          // Leaving Driving for Testing: stop fused / driving session.
          if (i == 0 && prev == 1) {
            unawaited(notifier.stopTracking());
          }
          // Do not stop simulation when opening Driving — simulation runs on the same session;
          // Home shows "Simulation running" while [isSimulating] stays true.
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.science_outlined),
            selectedIcon: Icon(Icons.science),
            label: 'Testing',
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_car_outlined),
            selectedIcon: Icon(Icons.directions_car),
            label: 'Driving',
          ),
        ],
      ),
    );
  }
}
