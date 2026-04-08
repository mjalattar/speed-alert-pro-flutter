import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../services/preferences_manager.dart';

/// Settings UI for simulation destination presets and optional lat/lng O/D fields.
class SimulationDestinationSettings extends ConsumerStatefulWidget {
  const SimulationDestinationSettings({super.key});

  @override
  ConsumerState<SimulationDestinationSettings> createState() =>
      _SimulationDestinationSettingsState();
}

class _SimulationDestinationSettingsState
    extends ConsumerState<SimulationDestinationSettings> {
  late TextEditingController _routingOrigin;
  late TextEditingController _routingDest;

  void _initControllers(PreferencesManager preferencesManager) {
    _routingOrigin =
        TextEditingController(text: preferencesManager.simulationRoutingOriginLatLng);
    _routingDest =
        TextEditingController(text: preferencesManager.simulationRoutingDestinationLatLng);
  }

  void _disposeControllers() {
    _routingOrigin.dispose();
    _routingDest.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initControllers(ref.read(preferencesProvider).preferencesManager);
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  void _bump() => ref.read(prefsRevisionProvider.notifier).state++;

  void _setPreset(int v) {
    final preferencesManager = ref.read(preferencesProvider).preferencesManager;
    _disposeControllers();
    preferencesManager.simulationDestinationPreset = v;
    _initControllers(preferencesManager);
    _bump();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final preferencesManager =
        ref.watch(preferencesProvider).preferencesManager;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Simulation destination', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        RadioListTile<int>(
          title: const Text(
            '618 Seafoam Ln, Kemah, TX → 2218 Dove Haven Ln, League City, TX',
          ),
          value: 0,
          groupValue: preferencesManager.simulationDestinationPreset,
          onChanged: (v) {
            if (v == null) return;
            _setPreset(v);
          },
        ),
        RadioListTile<int>(
          title: const Text(
            'Dove Haven Ln → 17511 El Camino Real, Houston, TX 77058',
          ),
          value: 1,
          groupValue: preferencesManager.simulationDestinationPreset,
          onChanged: (v) {
            if (v == null) return;
            _setPreset(v);
          },
        ),
        RadioListTile<int>(
          title: const Text('17511 El Camino Real → Dove Haven Ln, League City, TX'),
          value: 2,
          groupValue: preferencesManager.simulationDestinationPreset,
          onChanged: (v) {
            if (v == null) return;
            _setPreset(v);
          },
        ),
        RadioListTile<int>(
          title: const Text('Source & destination coordinates'),
          value: 3,
          groupValue: preferencesManager.simulationDestinationPreset,
          onChanged: (v) {
            if (v == null) return;
            _setPreset(v);
          },
        ),
        if (preferencesManager.simulationDestinationPreset == 3) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _routingOrigin,
            decoration: const InputDecoration(
              labelText: 'Source location',
              hintText: 'latitude,longitude',
              border: OutlineInputBorder(),
            ),
            onChanged: (s) {
              preferencesManager.simulationRoutingOriginLatLng = s;
            },
            onEditingComplete: _bump,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _routingDest,
            decoration: const InputDecoration(
              labelText: 'Destination location',
              hintText: 'latitude,longitude',
              border: OutlineInputBorder(),
            ),
            onChanged: (s) {
              preferencesManager.simulationRoutingDestinationLatLng = s;
            },
            onEditingComplete: _bump,
          ),
        ],
      ],
    );
  }
}
