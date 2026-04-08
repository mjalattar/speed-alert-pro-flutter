import 'dart:convert';
import 'dart:math' as math;

import '../../core/android_location_compat.dart';
import '../../core/speed_provider_constants.dart';
import '../../models/speed_limit_data.dart';
import '../mapbox/cross_track_geometry.dart';
import '../shared/geo_bearing.dart';
import '../shared/geo_coordinate.dart';

const double _alongEpsM = 0.5;

/// Speed limits tiled along a polyline (Mapbox `annotation.maxspeed` or TomTom Snap `route[]`).
/// Segment lengths use WGS84 geodesics via [AndroidLocationCompat].
class AnnotationSectionSpeedModel {
  AnnotationSectionSpeedModel._({
    required this.geometry,
    required List<MphSlice> slices,
    required this.totalLengthM,
    required this.expiresAtMillis,
    required this.provider,
    this.vehicleAnchorMph,
  }) : _slices = slices;

  final List<GeoCoordinate> geometry;
  final List<MphSlice> _slices;
  final double totalLengthM;
  final int expiresAtMillis;
  final String provider;

  /// TomTom: [projectedPoints] → [route[routeIndex]]. Mapbox: [annotation.maxspeed] at projected edge on route geometry.
  /// Independent of other providers; only encodes that vendor’s response at the vehicle.
  final int? vehicleAnchorMph;

  /// Posted mph per polyline edge (`geometry.length - 1`); null if slice layout does not match edges.
  List<int?>? mphHintsPerEdge() {
    final edges = geometry.length - 1;
    if (edges < 1 || _slices.length != edges) return null;
    return List<int?>.generate(edges, (i) => _slices[i].mph);
  }

  bool isExpired([int? nowMillis]) {
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    return now >= expiresAtMillis;
  }

  /// Posted limit from [MphSlice] tiling only (ignores [vehicleAnchorMph]). Used to debug anchor vs slice.
  int? sliceOnlyMphAtAlong(double alongMeters) {
    final along = alongMeters.clamp(0.0, totalLengthM + _alongEpsM);
    var containing = -1;
    for (var i = 0; i < _slices.length; i++) {
      final sl = _slices[i];
      if (along >= sl.fromM - _alongEpsM && along < sl.toM + _alongEpsM) {
        containing = i;
        break;
      }
    }
    if (containing >= 0) {
      return _slices[containing].mph;
    }
    if (_slices.isNotEmpty) {
      var j = -1;
      for (var i = 0; i < _slices.length; i++) {
        if (_slices[i].fromM <= along + _alongEpsM) j = i;
      }
      return j >= 0 ? _slices[j].mph : null;
    }
    return null;
  }

  SpeedLimitData speedLimitDataAtAlong(double alongMeters) {
    final along = alongMeters.clamp(0.0, totalLengthM + _alongEpsM);
    final anchor = vehicleAnchorMph;
    if (anchor != null &&
        provider == 'TomTom' &&
        along <= SpeedProviderConstants.tomtomSecondaryVehicleAnchorAlongMaxM) {
      return SpeedLimitData(
        provider: provider,
        speedLimitMph: anchor,
        confidence: ConfidenceLevel.high,
        source: 'TomTom route (vehicle snap)',
        segmentKey: 'tomtom:vehicle_anchor',
        functionalClass: null,
      );
    }
    if (anchor != null &&
        provider == 'Mapbox' &&
        along <= SpeedProviderConstants.mapboxSecondaryVehicleAnchorAlongMaxM) {
      return SpeedLimitData(
        provider: provider,
        speedLimitMph: anchor,
        confidence: ConfidenceLevel.high,
        source: 'Mapbox route (vehicle position)',
        segmentKey: 'mapbox:vehicle_anchor',
        functionalClass: null,
      );
    }
    var containing = -1;
    for (var i = 0; i < _slices.length; i++) {
      final sl = _slices[i];
      if (along >= sl.fromM - _alongEpsM && along < sl.toM + _alongEpsM) {
        containing = i;
        break;
      }
    }
    int? mph;
    String? segmentKey;
    if (containing >= 0) {
      mph = _slices[containing].mph;
      segmentKey = '$provider:slice:$containing';
    } else if (_slices.isNotEmpty) {
      var j = -1;
      for (var i = 0; i < _slices.length; i++) {
        if (_slices[i].fromM <= along + _alongEpsM) j = i;
      }
      mph = j >= 0 ? _slices[j].mph : null;
      segmentKey = j >= 0 ? '$provider:slice:$j' : null;
    }
    return SpeedLimitData(
      provider: provider,
      speedLimitMph: mph,
      confidence: mph != null ? ConfidenceLevel.high : ConfidenceLevel.low,
      source: '$provider route (along polyline)',
      segmentKey: segmentKey,
      functionalClass: null,
    );
  }

  static AnnotationSectionSpeedModel? fromMapboxDirectionsJson(
    String jsonStr, {
    int ttlMs = SpeedProviderConstants.mapboxSecondaryRouteModelTtlMs,
    double? vehicleLat,
    double? vehicleLng,
    double? headingDegrees,
  }) {
    try {
      final root = jsonDecode(jsonStr) as Map<String, dynamic>;
      final routes = root['routes'] as List<dynamic>?;
      final route = routes?.isNotEmpty == true ? routes!.first as Map<String, dynamic> : null;
      if (route == null) return null;
      final geom = route['geometry'] as Map<String, dynamic>?;
      final coords = geom?['coordinates'] as List<dynamic>?;
      final legs = route['legs'] as List<dynamic>?;
      final leg = legs?.isNotEmpty == true ? legs!.first as Map<String, dynamic> : null;
      final annotation = leg?['annotation'] as Map<String, dynamic>?;
      final arr = annotation?['maxspeed'] as List<dynamic>?;
      final n = coords?.length ?? 0;
      if (coords == null || n < 2 || arr == null) return null;
      final geo = <GeoCoordinate>[];
      for (var i = 0; i < n; i++) {
        final p = coords[i] as List<dynamic>;
        final lon = (p[0] as num).toDouble();
        final la = (p[1] as num).toDouble();
        geo.add(GeoCoordinate(la, lon));
      }
      final prefix = _vertexPrefixDistancesMeters(geo);
      final total = prefix.last;
      if (total < 1.0) return null;
      final edgeCount = n - 1;
      final sliceCount = edgeCount < arr.length ? edgeCount : arr.length;
      final slices = <MphSlice>[];
      int? lastMph;
      for (var i = 0; i < sliceCount; i++) {
        final mph = _parseMapboxMaxspeedEntry(arr, i) ?? lastMph;
        if (mph != null) lastMph = mph;
        slices.add(MphSlice(prefix[i], prefix[i + 1], mph));
      }
      for (var i = sliceCount; i < edgeCount; i++) {
        slices.add(MphSlice(prefix[i], prefix[i + 1], lastMph));
      }
      if (slices.isEmpty) return null;
      assert(() {
        assert(
          slices.length == edgeCount,
          'Mapbox maxspeed tiling: ${slices.length} slices vs $edgeCount edges',
        );
        return true;
      }());
      final vehicleAnchor = (vehicleLat != null &&
              vehicleLng != null &&
              vehicleLat.isFinite &&
              vehicleLng.isFinite)
          ? _mapboxVehicleMphAtGeometry(geo, arr, vehicleLat, vehicleLng, headingDegrees)
          : null;
      return AnnotationSectionSpeedModel._(
        geometry: geo,
        slices: slices,
        totalLengthM: total,
        expiresAtMillis: DateTime.now().millisecondsSinceEpoch + ttlMs,
        provider: 'Mapbox',
        vehicleAnchorMph: vehicleAnchor,
      );
    } catch (_) {
      return null;
    }
  }

  /// [annotation.maxspeed] entry for the edge containing the vehicle (project onto Mapbox route geometry only).
  static int? _mapboxVehicleMphAtGeometry(
    List<GeoCoordinate> geo,
    List<dynamic> maxspeedArr,
    double vehicleLat,
    double vehicleLng,
    double? headingDegrees,
  ) {
    final e = _mapboxVehicleEdgeProjectionFromGeometry(
      geo,
      maxspeedArr,
      vehicleLat,
      vehicleLng,
      headingDegrees,
    );
    return e?.edgeMph;
  }

  static MapboxVehicleEdgeProjection? _mapboxVehicleEdgeProjectionFromGeometry(
    List<GeoCoordinate> geo,
    List<dynamic> maxspeedArr,
    double vehicleLat,
    double vehicleLng,
    double? headingDegrees,
  ) {
    if (geo.length < 2 || maxspeedArr.isEmpty) return null;
    final proj = MapboxCrossTrackGeometry.projectOntoPolylineForMatching(
      vehicleLat,
      vehicleLng,
      geo,
      headingDegrees,
    );
    final seg = proj?.segmentIndex ?? 0;
    final lastSeg = geo.length - 2;
    final lastMs = maxspeedArr.length - 1;
    final cap = math.min(lastSeg, lastMs).toInt();
    final edgeIdx = seg.clamp(0, cap);
    final mph = _parseMapboxMaxspeedEntry(maxspeedArr, edgeIdx);
    return MapboxVehicleEdgeProjection(edgeIndex: edgeIdx, edgeMph: mph);
  }

  /// Debug: edge index + maxspeed at projected vehicle position on Mapbox directions geometry.
  static MapboxVehicleEdgeProjection? mapboxVehicleEdgeProjectionFromDirectionsJson(
    String jsonStr,
    double vehicleLat,
    double vehicleLng,
    double? headingDegrees,
  ) {
    try {
      final root = jsonDecode(jsonStr) as Map<String, dynamic>;
      final routes = root['routes'] as List<dynamic>?;
      final route = routes?.isNotEmpty == true ? routes!.first as Map<String, dynamic> : null;
      if (route == null) return null;
      final geom = route['geometry'] as Map<String, dynamic>?;
      final coords = geom?['coordinates'] as List<dynamic>?;
      final legs = route['legs'] as List<dynamic>?;
      final leg = legs?.isNotEmpty == true ? legs!.first as Map<String, dynamic> : null;
      final annotation = leg?['annotation'] as Map<String, dynamic>?;
      final arr = annotation?['maxspeed'] as List<dynamic>?;
      final n = coords?.length ?? 0;
      if (coords == null || n < 2 || arr == null) return null;
      final geo = <GeoCoordinate>[];
      for (var i = 0; i < n; i++) {
        final p = coords[i] as List<dynamic>;
        final lon = (p[0] as num).toDouble();
        final la = (p[1] as num).toDouble();
        geo.add(GeoCoordinate(la, lon));
      }
      return _mapboxVehicleEdgeProjectionFromGeometry(
        geo,
        arr,
        vehicleLat,
        vehicleLng,
        headingDegrees,
      );
    } catch (_) {
      return null;
    }
  }

  static AnnotationSectionSpeedModel? fromTomTomSnapRouteJson(
    String jsonStr, {
    int ttlMs = SpeedProviderConstants.tomtomSecondaryRouteModelTtlMs,
    double? vehicleLat,
    double? vehicleLng,
    double? headingDegrees,
  }) {
    try {
      final root = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (root['detailedError'] != null) return null;
      final route = _tomTomRouteElementsArray(root);
      if (route == null || route.isEmpty) return null;
      final vehicleAnchor = (vehicleLat != null &&
              vehicleLng != null &&
              vehicleLat.isFinite &&
              vehicleLng.isFinite)
          ? _tomTomVehicleSpeedMphFromSnapRoot(
              root,
              route,
              vehicleLat,
              vehicleLng,
              headingDegrees,
            )
          : null;
      final routeLen = route.length;
      final bounds = _tomTomRouteFeatureBoundsFromProjectedPoints(root, routeLen);
      var minI = bounds.$1;
      var maxI = bounds.$2;
      if (minI > maxI) {
        minI = 0;
        maxI = routeLen - 1;
      } else {
        final padded = _padTomTomRouteBounds(minI, maxI, routeLen, _tomTomRouteSlicePad);
        minI = padded.$1;
        maxI = padded.$2;
      }
      final built = _buildTomTomSnapSectionModel(route, minI, maxI, ttlMs, vehicleAnchor) ??
          _buildTomTomSnapSectionModel(route, 0, routeLen - 1, ttlMs, vehicleAnchor);
      return built;
    } catch (_) {
      return null;
    }
  }

  /// Resolves posted speed at the **vehicle** using TomTom [projectedPoints] → [route[routeIndex]].properties
  /// (not the merged polyline slice at [along], which can disagree when TomTom’s spine diverges).
  static int? _tomTomVehicleSpeedMphFromSnapRoot(
    Map<String, dynamic> root,
    List<dynamic> route,
    double vehicleLat,
    double vehicleLng,
    double? headingDegrees,
  ) {
    final p = _tomTomVehicleProjectionFromSnapRoot(
      root,
      route,
      vehicleLat,
      vehicleLng,
      headingDegrees,
    );
    return p?.anchorMph;
  }

  /// Debug: best [projectedPoints] match → speed, route feature index, snapped coordinates.
  static TomTomSnapVehicleProjection? tomTomVehicleProjectionFromSnapJson(
    String jsonStr,
    double vehicleLat,
    double vehicleLng, {
    double? headingDegrees,
  }) {
    try {
      final root = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (root['detailedError'] != null) return null;
      final route = _tomTomRouteElementsArray(root);
      if (route == null || route.isEmpty) return null;
      return _tomTomVehicleProjectionFromSnapRoot(
        root,
        route,
        vehicleLat,
        vehicleLng,
        headingDegrees,
      );
    } catch (_) {
      return null;
    }
  }

  /// Bearing (deg) along the first edge of TomTom route feature [routeIndex].
  static double? _tomTomFirstSegmentBearingDeg(List<dynamic> route, int routeIndex) {
    if (routeIndex < 0 || routeIndex >= route.length) return null;
    final feat = route[routeIndex] as Map<String, dynamic>?;
    final rawGeom = feat?['geometry'];
    if (rawGeom is! Map<String, dynamic>) return null;
    final coords = _tomTomLineStringCoordinates(rawGeom);
    if (coords == null || coords.length < 2) return null;
    final p0 = coords[0] as List<dynamic>;
    final p1 = coords[1] as List<dynamic>;
    final lon0 = (p0[0] as num).toDouble();
    final la0 = (p0[1] as num).toDouble();
    final lon1 = (p1[0] as num).toDouble();
    final la1 = (p1[1] as num).toDouble();
    return bearingDeg(la0, lon0, la1, lon1);
  }

  static TomTomSnapVehicleProjection? _tomTomVehicleProjectionFromSnapRoot(
    Map<String, dynamic> root,
    List<dynamic> route,
    double vehicleLat,
    double vehicleLng,
    double? headingDegrees,
  ) {
    final projected = root['projectedPoints'] as List<dynamic>?;
    if (projected == null || projected.isEmpty) {
      final feat0 = route.isNotEmpty ? route[0] as Map<String, dynamic>? : null;
      final props0 = feat0?['properties'] as Map<String, dynamic>? ?? {};
      final m = _mphFromTomTomRoadProperties(props0);
      if (m == null) return null;
      return TomTomSnapVehicleProjection(
        anchorMph: m,
        routeIndex: 0,
        snapLat: vehicleLat,
        snapLng: vehicleLng,
        snapDistanceM: 0,
      );
    }
    final candidates = <({TomTomSnapVehicleProjection p, double d})>[];
    for (final raw in projected) {
      final pf = raw as Map<String, dynamic>?;
      if (pf == null) continue;
      final pprops = pf['properties'] as Map<String, dynamic>? ?? {};
      final snap = pprops['snapResult']?.toString().trim() ?? '';
      if (!_tomTomSnapResultForRouteBounds(snap)) continue;
      final ri = _tomTomRouteIndexFromProperties(pprops);
      if (ri < 0 || ri >= route.length) continue;
      final geom = pf['geometry'] as Map<String, dynamic>?;
      if (geom == null) continue;
      final coords = geom['coordinates'];
      if (coords is! List || coords.length < 2) continue;
      final lon = (coords[0] as num).toDouble();
      final la = (coords[1] as num).toDouble();
      final d = AndroidLocationCompat.distanceBetweenMeters(
        vehicleLat,
        vehicleLng,
        la,
        lon,
      );
      final feat = route[ri] as Map<String, dynamic>?;
      final props = feat?['properties'] as Map<String, dynamic>? ?? {};
      final mph = _mphFromTomTomRoadProperties(props);
      if (mph == null) continue;
      candidates.add((
        p: TomTomSnapVehicleProjection(
          anchorMph: mph,
          routeIndex: ri,
          snapLat: la,
          snapLng: lon,
          snapDistanceM: d,
        ),
        d: d,
      ));
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => a.d.compareTo(b.d));
    final minD = candidates.first.d;
    if (headingDegrees != null &&
        headingDegrees.isFinite &&
        candidates.length > 1) {
      final near = candidates
          .where(
            (c) =>
                c.d <=
                minD + SpeedProviderConstants.tomtomProjectedPointHeadingTieM,
          )
          .toList();
      if (near.length > 1) {
        var bestScore = double.infinity;
        TomTomSnapVehicleProjection? bestHeadingPick;
        for (final c in near) {
          final brg = _tomTomFirstSegmentBearingDeg(route, c.p.routeIndex);
          if (brg == null) {
            if (c.d < bestScore) {
              bestScore = c.d;
              bestHeadingPick = c.p;
            }
            continue;
          }
          final delta = smallestBearingDeltaDeg(headingDegrees, brg);
          final score = c.d + delta * 0.35;
          if (score < bestScore) {
            bestScore = score;
            bestHeadingPick = c.p;
          }
        }
        if (bestHeadingPick != null) return bestHeadingPick;
      }
    }
    return candidates.first.p;
  }

  static AnnotationSectionSpeedModel? _buildTomTomSnapSectionModel(
    List<dynamic> route,
    int startFi,
    int endFi,
    int ttlMs,
    int? vehicleAnchorMph,
  ) {
    final merged = <GeoCoordinate>[];
    final slices = <MphSlice>[];
    var cum = 0.0;
    int? lastMph;
    final safeStart = startFi.clamp(0, route.length - 1);
    final safeEnd = endFi.clamp(0, route.length - 1);
    for (var fi = safeStart; fi <= safeEnd; fi++) {
      final feat = route[fi] as Map<String, dynamic>?;
      if (feat == null) continue;
      final props = feat['properties'] as Map<String, dynamic>? ?? {};
      var mph = _mphFromTomTomRoadProperties(props) ?? lastMph;
      if (mph != null) lastMph = mph;
      final geom = feat['geometry'] as Map<String, dynamic>?;
      if (geom == null) continue;
      final coords = _tomTomLineStringCoordinates(geom);
      if (coords == null) continue;
      for (var j = 0; j < coords.length; j++) {
        final p = coords[j] as List<dynamic>;
        final lon = (p[0] as num).toDouble();
        final la = (p[1] as num).toDouble();
        final g = GeoCoordinate(la, lon);
        if (merged.isEmpty) {
          merged.add(g);
          continue;
        }
        final prev = merged.last;
        if ((prev.lat - g.lat).abs() < 1e-7 && (prev.lng - g.lng).abs() < 1e-7) {
          continue;
        }
        final len = AndroidLocationCompat.distanceBetweenMeters(
          prev.lat,
          prev.lng,
          g.lat,
          g.lng,
        );
        if (len < 1e-6) {
          merged.add(g);
          continue;
        }
        slices.add(MphSlice(cum, cum + len, mph));
        cum += len;
        merged.add(g);
      }
    }
    if (merged.length < 2) return null;
    final prefix = _vertexPrefixDistancesMeters(merged);
    final total = prefix.last;
    if (total < 1.0) return null;
    if (slices.isEmpty) {
      slices.add(MphSlice(0, total, lastMph));
      cum = total;
    }
    if ((cum - total).abs() > 2.0 && slices.isNotEmpty) {
      final last = slices.last;
      slices[slices.length - 1] = MphSlice(last.fromM, total, last.mph);
    }
    return AnnotationSectionSpeedModel._(
      geometry: merged,
      slices: slices,
      totalLengthM: total,
      expiresAtMillis: DateTime.now().millisecondsSinceEpoch + ttlMs,
      provider: 'TomTom',
      vehicleAnchorMph: vehicleAnchorMph,
    );
  }

  static List<dynamic>? _tomTomRouteElementsArray(Map<String, dynamic> root) {
    final direct = root['route'];
    if (direct is List<dynamic>) return direct;
    if (direct is Map<String, dynamic>) {
      final feats = direct['features'];
      if (feats is List<dynamic>) return feats;
      final t = direct['type']?.toString() ?? '';
      if (t.toLowerCase() == 'feature' && direct.containsKey('geometry')) {
        return [direct];
      }
    }
    return null;
  }

  static const int _tomTomRouteSlicePad = 8;

  static (int, int) _padTomTomRouteBounds(int minI, int maxI, int routeLen, int pad) {
    final s = (minI - pad).clamp(0, routeLen - 1);
    final e = (maxI + pad).clamp(0, routeLen - 1);
    return (s, e);
  }

  static (int, int) _tomTomRouteFeatureBoundsFromProjectedPoints(
    Map<String, dynamic> root,
    int routeLen,
  ) {
    final projected = root['projectedPoints'] as List<dynamic>?;
    if (projected == null) return (0, routeLen - 1);
    var minI = 0x7fffffff;
    var maxI = -0x80000000;
    var any = false;
    for (var pi = 0; pi < projected.length; pi++) {
      final pf = projected[pi] as Map<String, dynamic>?;
      if (pf == null) continue;
      final pprops = pf['properties'] as Map<String, dynamic>? ?? {};
      final snap = pprops['snapResult']?.toString().trim() ?? '';
      if (!_tomTomSnapResultForRouteBounds(snap)) continue;
      final ri = _tomTomRouteIndexFromProperties(pprops);
      if (ri < 0 || ri >= routeLen) continue;
      any = true;
      if (ri < minI) minI = ri;
      if (ri > maxI) maxI = ri;
    }
    if (!any) return (0, routeLen - 1);
    return (minI, maxI);
  }

  static bool _tomTomSnapResultForRouteBounds(String snapResult) {
    final s = snapResult.trim();
    return s.isEmpty || s.toLowerCase() == 'matched';
  }

  static int _tomTomRouteIndexFromProperties(Map<String, dynamic> pprops) {
    if (!pprops.containsKey('routeIndex')) return -1;
    final r = pprops['routeIndex'];
    if (r is num) {
      final k = r.round();
      return k >= 0 ? k : -1;
    }
    return -1;
  }

  static List<dynamic>? _tomTomLineStringCoordinates(Map<String, dynamic> geom) {
    final type = geom['type']?.toString() ?? '';
    if (type.toLowerCase() == 'linestring') {
      return geom['coordinates'] as List<dynamic>?;
    }
    if (type.toLowerCase() == 'multilinestring') {
      final rings = geom['coordinates'] as List<dynamic>?;
      return rings?.isNotEmpty == true ? rings!.first as List<dynamic>? : null;
    }
    if (type.toLowerCase() == 'polygon') {
      final rings = geom['coordinates'] as List<dynamic>?;
      return rings?.isNotEmpty == true ? rings!.first as List<dynamic>? : null;
    }
    return null;
  }

  static int? _mphFromTomTomRoadProperties(Map<String, dynamic> props) {
    final fromSl = _mphFromTomTomSpeedLimits(props);
    if (fromSl != null) return fromSl;
    final sp = props['speedProfile'];
    if (sp is Map<String, dynamic>) {
      return _parseTomTomValueUnitMph(sp);
    }
    return null;
  }

  static int? _mphFromTomTomSpeedLimits(Map<String, dynamic> props) {
    final raw = props['speedLimits'];
    if (raw is Map<String, dynamic>) {
      return _parseTomTomSlObject(raw);
    }
    if (raw is List<dynamic>) {
      int? fallback;
      for (var j = 0; j < raw.length; j++) {
        final o = raw[j] as Map<String, dynamic>?;
        if (o == null) continue;
        final mph = _parseTomTomSlObject(o);
        if (mph == null) continue;
        final t = o['type']?.toString() ?? '';
        if (t.toLowerCase().contains('advisory')) {
          fallback ??= mph;
          continue;
        }
        return mph;
      }
      return fallback;
    }
    return null;
  }

  static int? _parseTomTomSlObject(Map<String, dynamic> sl) =>
      _parseTomTomValueUnitMph(sl);

  static int? _parseTomTomValueUnitMph(Map<String, dynamic> o) {
    if (!o.containsKey('value')) return null;
    final rawVal = o['value'];
    int value;
    if (rawVal is String) {
      value = double.tryParse(rawVal.trim())?.round() ?? -1;
    } else if (rawVal is num) {
      value = rawVal.round();
    } else {
      final vd = o['value'];
      if (vd is num) {
        value = vd.round();
      } else {
        return null;
      }
    }
    if (value < 0) return null;
    final unit = (o['unit']?.toString() ?? 'kmph').toLowerCase();
    if (unit.contains('mph')) return value;
    return (value * 0.621371).round();
  }

  static int? _parseMapboxMaxspeedEntry(List<dynamic> arr, int index) {
    if (index >= arr.length) return null;
    final item = arr[index];
    if (item is! Map<String, dynamic>) return null;
    if (item['unknown'] == true || item['none'] == true) return null;
    if (!item.containsKey('speed')) return null;
    final speed = (item['speed'] as num?)?.toDouble();
    if (speed == null) return null;
    final unit = (item['unit']?.toString() ?? '').toLowerCase();
    if (unit.contains('mph')) return speed.round();
    if (unit.contains('km') || unit.isEmpty) {
      return (speed * 0.621371).round();
    }
    return (speed * 0.621371).round();
  }

  static List<double> _vertexPrefixDistancesMeters(List<GeoCoordinate> geometry) {
    final n = geometry.length;
    final d = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      d[i] = d[i - 1] +
          AndroidLocationCompat.distanceBetweenMeters(
            geometry[i - 1].lat,
            geometry[i - 1].lng,
            geometry[i].lat,
            geometry[i].lng,
          );
    }
    return d;
  }
}

class MphSlice {
  const MphSlice(this.fromM, this.toM, this.mph);

  final double fromM;
  final double toM;
  final int? mph;
}

/// TomTom Snap API: vehicle anchor from [projectedPoints] → [route[routeIndex]] (debug / logging).
class TomTomSnapVehicleProjection {
  const TomTomSnapVehicleProjection({
    required this.anchorMph,
    required this.routeIndex,
    required this.snapLat,
    required this.snapLng,
    required this.snapDistanceM,
  });

  final int anchorMph;
  final int routeIndex;
  final double snapLat;
  final double snapLng;
  final double snapDistanceM;
}

/// Mapbox Directions: `annotation.maxspeed` edge at projected vehicle position (debug / logging).
class MapboxVehicleEdgeProjection {
  const MapboxVehicleEdgeProjection({
    required this.edgeIndex,
    required this.edgeMph,
  });

  final int edgeIndex;
  final int? edgeMph;
}
