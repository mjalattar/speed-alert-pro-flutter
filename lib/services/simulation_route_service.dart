import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../engine/geo_coordinate.dart';
import '../engine/here_section_speed_model.dart';
import '../providers/app_providers.dart';
import 'preferences_manager.dart';

// Preset simulation O/D strings (`lat,lng` comma form).

const String kSimulationDefaultOriginLatLng = '29.5445,-95.0205';
const String kPresetSimDoveLatLng = '29.5140547,-95.0674492';
const String kPresetSimNrgLatLng = '29.6845,-95.4104';
const String kPresetSimElcaminoLatLng = '29.5500637,-95.1106676';
const String kPresetSimDoveHavenStartLatLng = kPresetSimDoveLatLng;
const String kPresetSimIslaLeagueOriginLatLng = '29.5262731,-95.0114404';
const String kPresetSimIslaLeagueDestLatLng = '29.5240499,-95.0173834';

/// Parses `"lat,lng"` into coordinates or returns null if invalid.
({double lat, double lng})? parseLatLngComma(String s) {
  final parts = s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (parts.length != 2) return null;
  final lat = double.tryParse(parts[0]);
  final lng = double.tryParse(parts[1]);
  if (lat == null || lng == null) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  return (lat: lat, lng: lng);
}

/// Origin string for the current simulation preset / custom routing fields.
String simulationRouteOriginLatLng(PreferencesManager preferencesManager) {
  final preset = preferencesManager.simulationDestinationPreset;
  switch (preset) {
    case 2:
      return kPresetSimDoveHavenStartLatLng;
    case 3:
      return kPresetSimElcaminoLatLng;
    case 5:
      return preferencesManager.simulationRoutingOriginLatLng.trim();
    case 6:
      return kPresetSimIslaLeagueOriginLatLng;
    default:
      return kSimulationDefaultOriginLatLng;
  }
}

/// Destination string for the current simulation preset / custom fields.
String simulationRouteDestinationLatLngString(
  PreferencesManager preferencesManager,
) {
  final preset = preferencesManager.simulationDestinationPreset;
  switch (preset) {
    case 0:
    case 3:
      return kPresetSimDoveLatLng;
    case 1:
      return kPresetSimNrgLatLng;
    case 2:
      return kPresetSimElcaminoLatLng;
    case 4:
      return preferencesManager.simulationCustomDestinationLatLng.trim();
    case 5:
      return preferencesManager.simulationRoutingDestinationLatLng.trim();
    case 6:
      return kPresetSimIslaLeagueDestLatLng;
    default:
      return preferencesManager.simulationCustomDestinationLatLng.trim();
  }
}

/// Resolves HERE route geometry for road-test simulation.
///
/// [sectionSpeedModel] is built from the **same** O–D `v8/routes` (or Edge `kind: route`) response as
/// [path] so [LocationProcessor] section-walks the identical polyline as the mock vehicle (one fetch for
/// map + HERE spans; avoids alert-leg geometry mismatch and refetch storms).
///
/// Returns empty [path] if origin/destination invalid or APIs yield no polyline — **no** synthetic
/// fallback (simulation does not start).
Future<({List<GeoCoordinate> path, HereSectionSpeedModel? sectionSpeedModel})> resolveSimulationRoute(
  Ref ref,
) async {
  final preferencesManager = ref.read(preferencesProvider).preferencesManager;
  final edgeClient = ref.read(hereEdgeFunctionClientProvider);
  final hereApi = ref.read(hereApiServiceProvider);

  var destStr = simulationRouteDestinationLatLngString(preferencesManager).trim();

  // Preset 4 + blank custom lat/lng → HERE Discover on [simulationCustomDestinationQuery].
  if (preferencesManager.simulationDestinationPreset == 4 && destStr.isEmpty) {
    final q = preferencesManager.simulationCustomDestinationQuery.trim();
    if (q.isNotEmpty && AppConfig.hereApiKey.isNotEmpty) {
      final pos = await hereApi.discoverFirstPosition(query: q);
      if (pos != null) {
        destStr = '${pos.lat},${pos.lng}';
        preferencesManager.simulationCustomDestinationLatLng = destStr;
        ref.read(prefsRevisionProvider.notifier).state++;
      }
    }
  }

  if (destStr.isEmpty) {
    return (path: <GeoCoordinate>[], sectionSpeedModel: null);
  }

  final originStr = simulationRouteOriginLatLng(preferencesManager).trim();
  var o = parseLatLngComma(originStr);
  var d = parseLatLngComma(destStr);

  // Preset 5: require valid both ends.
  if (preferencesManager.simulationDestinationPreset == 5 && (o == null || d == null)) {
    return (path: <GeoCoordinate>[], sectionSpeedModel: null);
  }
  if (o == null || d == null) {
    return (path: <GeoCoordinate>[], sectionSpeedModel: null);
  }

  final oLat = o.lat;
  final oLng = o.lng;
  final dLat = d.lat;
  final dLng = d.lng;

  final canSimViaRemote = AppConfig.useRemoteHere &&
      preferencesManager.useRemoteSpeedApi &&
      edgeClient != null;

  if (!preferencesManager.isHereApiEnabled && !canSimViaRemote) {
    return (path: <GeoCoordinate>[], sectionSpeedModel: null);
  }

  if (canSimViaRemote) {
    try {
      final bundle = await edgeClient.fetchRoutePolylineForSimulation(
        originLat: oLat,
        originLng: oLng,
        destLat: dLat,
        destLng: dLng,
      );
      if (bundle != null && bundle.geometry.length >= 2) {
        final parsed = hereApi.parseAlertFetchFromDecodedRoute(
          bundle.root,
          lat: oLat,
          lng: oLng,
        );
        return (path: bundle.geometry, sectionSpeedModel: parsed.sectionSpeedModel);
      }
    } catch (_) {}
  }

  // Local HERE: single O–D routing response decodes map polyline + spans.
  if (preferencesManager.isHereApiEnabled && AppConfig.hereApiKey.isNotEmpty) {
    try {
      final od = await hereApi.fetchSimulationOdRouteWithSection(
        origin: '$oLat,$oLng',
        destination: '$dLat,$dLng',
      );
      if (od != null && od.geometry.length >= 2) {
        return (path: od.geometry, sectionSpeedModel: od.sectionSpeedModel);
      }
    } catch (_) {}
  }

  return (path: <GeoCoordinate>[], sectionSpeedModel: null);
}
