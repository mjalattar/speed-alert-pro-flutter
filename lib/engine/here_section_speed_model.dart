import '../core/android_location_compat.dart';
import '../models/speed_limit_data.dart';
import 'geo_coordinate.dart';

const _alongEpsM = 0.5;
const _spanGapMergeEpsM = 0.5;

/// HERE span from JSON.
class HereSpan {
  HereSpan({
    required this.offset,
    required this.length,
    this.speedLimitMps,
    this.segmentRef,
    this.functionalClass,
  });

  final int offset;
  final int length;
  final double? speedLimitMps;
  final String? segmentRef;
  final double? functionalClass;

  /// Kotlin Gson: missing [offset]/[length] on [Span] deserialize as **0** (non-nullable [Int]).
  /// Dropping those spans made [spans] empty so HERE returned 200 with limits in the raw JSON but
  /// [parseAlertFetchFromDecodedRoute] yielded `network_no_mph`.
  static int _routingIntField(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }

  static double? _routingSpeedLimitMps(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  /// HERE Routing `v8/routes` section span — same field coercion as Kotlin [Span] + Gson defaults.
  static HereSpan fromHereRoutingApiJson(Map<String, dynamic> m) {
    return HereSpan(
      offset: _routingIntField(m['offset']),
      length: _routingIntField(m['length']),
      speedLimitMps: _routingSpeedLimitMps(m['speedLimit']),
      segmentRef: m['segmentRef'] as String?,
      functionalClass: (m['functionalClass'] as num?)?.toDouble(),
    );
  }

  factory HereSpan.fromJson(Map<String, dynamic> m) =>
      HereSpan.fromHereRoutingApiJson(m);

  String stableTopologyKey() {
    final ref = segmentRef?.trim();
    final stableRef = ref?.split('#').first.trim();
    final base = (stableRef != null && stableRef.isNotEmpty)
        ? stableRef
        : 'o${offset}_l$length';
    final fc = functionalClass;
    final fcInt = fc != null ? fc.round() : null;
    if (fcInt != null) return '$base|fc:$fcInt';
    return base;
  }
}

class SpanSlice {
  SpanSlice(this.fromM, this.toM, this.span);
  final double fromM;
  final double toM;
  final HereSpan span;
}

/// Mirrors Kotlin [HereSectionSpeedModel].
/// VERIFIED: 1:1 Logic match with Kotlin (prefix distances via Android [Location.distanceTo]).
class HereSectionSpeedModel {
  HereSectionSpeedModel({
    required this.geometry,
    required this.slices,
    required this.totalLengthM,
    required this.expiresAtMillis,
  });

  final List<GeoCoordinate> geometry;
  final List<SpanSlice> slices;
  final double totalLengthM;
  final int expiresAtMillis;

  bool isExpired([int? nowMs]) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return now >= expiresAtMillis;
  }

  SpeedLimitData speedLimitDataAtAlong(double alongMeters) {
    final along = alongMeters.clamp(0.0, totalLengthM + _alongEpsM);
    final span = _spanForAlong(along);
    return speedLimitDataFromSpan(span);
  }

  HereSpan? _spanForAlong(double along) {
    if (slices.isEmpty) return null;
    var containing = -1;
    for (var i = 0; i < slices.length; i++) {
      final sl = slices[i];
      if (along >= sl.fromM - _alongEpsM && along < sl.toM + _alongEpsM) {
        containing = i;
        break;
      }
    }
    if (containing < 0) {
      for (var i = slices.length - 1; i >= 0; i--) {
        if (slices[i].fromM <= along + _alongEpsM) {
          containing = i;
          break;
        }
      }
    }
    if (containing < 0) return slices.first.span;

    var j = containing;
    while (j >= 0 && slices[j].span.speedLimitMps == null) j--;
    if (j >= 0) return slices[j].span;
    j = containing;
    while (j < slices.length && slices[j].span.speedLimitMps == null) j++;
    return j < slices.length ? slices[j].span : slices[containing].span;
  }

  static HereSectionSpeedModel? build(
    List<HereSpan> spans,
    List<GeoCoordinate> geometry, {
    int ttlMs = 30 * 60 * 1000,
  }) {
    if (geometry.length < 2 || spans.isEmpty) return null;
    final ordered = [...spans]..sort((a, b) => a.offset.compareTo(b.offset));
    final prefix = _vertexPrefixDistancesMeters(geometry);
    final total = prefix.last;
    if (total < 1.0) return null;
    final n = geometry.length;
    var slices = _buildSpanSlices(ordered, n, prefix, true);
    if (slices.isEmpty) return null;
    var coverageM = slices.map((s) => s.toM).reduce((a, b) => a > b ? a : b);
    if (coverageM < total * 0.85) {
      final alt = _buildSpanSlices(ordered, n, prefix, false);
      final altCover = alt.isEmpty ? 0.0 : alt.map((s) => s.toM).reduce((a, b) => a > b ? a : b);
      if (alt.isNotEmpty && altCover > coverageM + 5.0) {
        slices = alt;
      }
    }
    final normalized = _normalizeSpanSlices(slices, total);
    if (normalized.isEmpty) return null;
    return HereSectionSpeedModel(
      geometry: geometry,
      slices: normalized,
      totalLengthM: total,
      expiresAtMillis: DateTime.now().millisecondsSinceEpoch + ttlMs,
    );
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

  static List<SpanSlice> _buildSpanSlices(
    List<HereSpan> spans,
    int vertexCount,
    List<double> prefix,
    bool edgesMode,
  ) {
    final out = <SpanSlice>[];
    for (final sp in spans) {
      final range = edgesMode
          ? _spanToMeterRangeEdges(sp, vertexCount, prefix)
          : _spanToMeterRangeVertexCount(sp, vertexCount, prefix);
      if (range != null) {
        out.add(SpanSlice(range.$1, range.$2, sp));
      }
    }
    return out;
  }

  static (double, double)? _spanToMeterRangeEdges(
    HereSpan span,
    int vertexCount,
    List<double> prefix,
  ) {
    final lastV = vertexCount - 1;
    final startV = span.offset.clamp(0, lastV);
    var edges = span.length;
    if (edges < 1) edges = 1;
    final endV = (startV + edges).clamp(startV + 1, lastV);
    final fromM = prefix[startV];
    final toM = prefix[endV];
    if (toM <= fromM + 1e-6) return null;
    return (fromM, toM);
  }

  static (double, double)? _spanToMeterRangeVertexCount(
    HereSpan span,
    int vertexCount,
    List<double> prefix,
  ) {
    final lastV = vertexCount - 1;
    final startV = span.offset.clamp(0, lastV);
    var vCount = span.length < 1 ? 1 : span.length;
    var endV = (startV + vCount - 1).clamp(startV, lastV);
    if (endV == startV && startV < lastV) endV = startV + 1;
    final fromM = prefix[startV];
    final toM = prefix[endV];
    if (toM <= fromM + 1e-6) return null;
    return (fromM, toM);
  }

  static List<SpanSlice> _normalizeSpanSlices(List<SpanSlice> slices, double totalM) {
    if (slices.isEmpty) return [];
    final sorted = [...slices]..sort((a, b) => a.fromM.compareTo(b.fromM));
    final out = <SpanSlice>[];
    var prevTo = 0.0;
    for (final s in sorted) {
      var from = s.fromM.clamp(0.0, totalM);
      final to = s.toM.clamp(0.0, totalM);
      if (from < prevTo) from = prevTo;
      if (from >= to) continue;
      if (out.isNotEmpty && from > prevTo + _spanGapMergeEpsM) {
        final last = out.removeLast();
        out.add(SpanSlice(last.fromM, from, last.span));
      }
      out.add(SpanSlice(from, to, s.span));
      prevTo = to;
    }
    if (out.isNotEmpty && out.last.toM < totalM - 0.1) {
      final last = out.removeLast();
      out.add(SpanSlice(last.fromM, totalM, last.span));
    }
    return out;
  }
}

SpeedLimitData speedLimitDataFromSpan(HereSpan? span) {
  if (span?.speedLimitMps == null) {
    return const SpeedLimitData(
      provider: 'HERE Maps',
      speedLimitMph: null,
      confidence: ConfidenceLevel.low,
      source: 'HERE Routing API: no speed for span',
    );
  }
  final mph = (span!.speedLimitMps! * 2.23694).round();
  return SpeedLimitData(
    provider: 'HERE Maps',
    speedLimitMph: mph,
    confidence: ConfidenceLevel.high,
    source: 'HERE Routing API (span)',
    segmentKey: span.stableTopologyKey(),
    functionalClass: span.functionalClass?.round(),
  );
}
