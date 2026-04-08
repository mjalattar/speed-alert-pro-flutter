import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../engine/shared/geo_coordinate.dart';
import '../engine/here/section_speed_model.dart';
import '../providers/app_providers.dart';
import 'preferences_manager.dart';

// Preset simulation O/D strings (`lat,lng` comma form).

const String kSimulationDefaultOriginLatLng = '29.5445,-95.0205';
/// Preset 0 origin (first simulation destination option).
const String kPresetSimKemahSeafoam618LatLng = '29.526066,-95.015461';
/// First-preset destination (decimal degrees).
const String kPresetSimLeagueCityDove2218LatLng = '29.514089,-95.065802';
const String kPresetSimDoveLatLng = '29.5140547,-95.0674492';
const String kPresetSimElcaminoLatLng = '29.5500637,-95.1106676';
const String kPresetSimDoveHavenStartLatLng = kPresetSimDoveLatLng;

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
    case 0:
      return kPresetSimKemahSeafoam618LatLng;
    case 1:
      return kPresetSimDoveHavenStartLatLng;
    case 2:
      return kPresetSimElcaminoLatLng;
    case 3:
      return preferencesManager.simulationRoutingOriginLatLng.trim();
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
      return kPresetSimLeagueCityDove2218LatLng;
    case 1:
      return kPresetSimElcaminoLatLng;
    case 2:
      return kPresetSimDoveLatLng;
    case 3:
      return preferencesManager.simulationRoutingDestinationLatLng.trim();
    default:
      return '';
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
Future<({
  List<GeoCoordinate> path,
  HereSectionSpeedModel? sectionSpeedModel,
  bool usedRemoteEdge,
})> resolveSimulationRoute(
  Ref ref,
) async {
  final preferencesManager = ref.read(preferencesProvider).preferencesManager;
  final edgeClient = ref.read(remoteEdgeFunctionClientProvider);
  final hereApi = ref.read(hereApiServiceProvider);

  var destStr = simulationRouteDestinationLatLngString(preferencesManager).trim();

  if (destStr.isEmpty) {
    return (path: <GeoCoordinate>[], sectionSpeedModel: null, usedRemoteEdge: false);
  }

  final originStr = simulationRouteOriginLatLng(preferencesManager).trim();
  var o = parseLatLngComma(originStr);
  var d = parseLatLngComma(destStr);

  // Preset 3 (coordinates): require valid both ends.
  if (preferencesManager.simulationDestinationPreset == 3 && (o == null || d == null)) {
    return (path: <GeoCoordinate>[], sectionSpeedModel: null, usedRemoteEdge: false);
  }
  if (o == null || d == null) {
    return (path: <GeoCoordinate>[], sectionSpeedModel: null, usedRemoteEdge: false);
  }

  final oLat = o.lat;
  final oLng = o.lng;
  final dLat = d.lat;
  final dLng = d.lng;

  final canSimViaRemote = AppConfig.useRemoteHere &&
      preferencesManager.isRemoteApiEnabled &&
      edgeClient != null;

  if (!preferencesManager.isHereApiEnabled && !canSimViaRemote) {
    return (path: <GeoCoordinate>[], sectionSpeedModel: null, usedRemoteEdge: false);
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
        return (
          path: bundle.geometry,
          sectionSpeedModel: parsed.sectionSpeedModel,
          usedRemoteEdge: true,
        );
      }
    } catch (_) {}
  }

  // HERE on device: single O–D routing response decodes map polyline + spans.
  if (preferencesManager.isHereApiEnabled && AppConfig.hereApiKey.isNotEmpty) {
    try {
      final od = await hereApi.fetchSimulationOdRouteWithSection(
        origin: '$oLat,$oLng',
        destination: '$dLat,$dLng',
      );
      if (od != null && od.geometry.length >= 2) {
        return (
          path: od.geometry,
          sectionSpeedModel: od.sectionSpeedModel,
          usedRemoteEdge: false,
        );
      }
    } catch (_) {}
  }

  return (path: <GeoCoordinate>[], sectionSpeedModel: null, usedRemoteEdge: false);
}
