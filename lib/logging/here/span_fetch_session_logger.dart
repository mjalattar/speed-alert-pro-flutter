import '../../engine/here/section_speed_model.dart';
import '../../services/preferences_manager.dart';
import '../csv_escape.dart';
import '../log_export_platform.dart';
import '../speed_debug_log_session.dart';
import '../speed_limit_api_request_logger.dart';

/// Records per-span mph slices from local HERE route JSON for debug export.
class HereSpanFetchSessionLogger {
  HereSpanFetchSessionLogger._();

  static final List<_FetchRecord> _fetches = [];

  static void clearSession() {
    _fetches.clear();
  }

  /// Record from decoded HERE `v8/routes` JSON (local path only).
  static void recordLocalRouteIfApplicable(
    PreferencesManager preferencesManager,
    double lat,
    double lng,
    Map<String, dynamic> routeRoot,
  ) {
    if (!SpeedDebugLogSessionHolder.isSessionActive()) return;
    final spanMph = _spanSpeedMphList(routeRoot);
    if (spanMph.isEmpty) return;
    final spanDetails = _spanDetailList(routeRoot);
    _fetches.add(
      _FetchRecord(
        utc: SpeedLimitApiRequestLogger.utcNow(),
        lat: lat,
        lng: lng,
        spanMph: spanMph,
        spanDetails: spanDetails,
      ),
    );
  }

  static List<int?> _spanSpeedMphList(Map<String, dynamic> response) {
    final routes = response['routes'] as List<dynamic>?;
    final route = routes?.isNotEmpty == true ? routes!.first as Map<String, dynamic>? : null;
    final sections = route?['sections'] as List<dynamic>?;
    final section = sections?.isNotEmpty == true ? sections!.first as Map<String, dynamic>? : null;
    final spans = section?['spans'] as List<dynamic>? ?? [];
    return spans.map((sp) {
      final m = sp as Map<String, dynamic>;
      final mps = m['speedLimit'];
      if (mps is num) return (mps.toDouble() * 2.23694).round();
      return null;
    }).toList();
  }

  static List<_SpanDetail> _spanDetailList(Map<String, dynamic> response) {
    final routes = response['routes'] as List<dynamic>?;
    final route = routes?.isNotEmpty == true ? routes!.first as Map<String, dynamic>? : null;
    final sections = route?['sections'] as List<dynamic>?;
    final section = sections?.isNotEmpty == true ? sections!.first as Map<String, dynamic>? : null;
    final spans = section?['spans'] as List<dynamic>? ?? [];
    return spans.map((sp) {
      final m = sp as Map<String, dynamic>;
      final hs = HereSpan.fromHereRoutingApiJson(m);
      final seg = hs.segmentRef?.trim();
      final segShort = seg != null && seg.length > 48 ? '${seg.substring(0, 45)}…' : seg;
      return _SpanDetail(
        lengthM: hs.length,
        functionalClass: hs.functionalClass?.round(),
        segmentRefShort: segShort,
      );
    }).toList();
  }

  static String _csvLine(List<String> fields) =>
      fields.map((f) => CsvEscape.escape(f)).join(',');

  static Future<String?> copySessionToPublicDownloads(
    SpeedDebugLogSession session,
  ) async {
    if (session == SpeedDebugLogSession.none) return null;
    if (_fetches.isEmpty) return null;
    final buf = StringBuffer()
      ..writeln(
        _csvLine([
          'session',
          'fetch_seq',
          'fetch_utc',
          'vehicle_lat',
          'vehicle_lng',
          'span_index',
          'limit_mph',
          'length_m',
          'functional_class',
          'segment_ref',
        ]),
      );
    final sess = session.name;
    for (var idx = 0; idx < _fetches.length; idx++) {
      final rec = _fetches[idx];
      for (var i = 0; i < rec.spanMph.length; i++) {
        final mph = rec.spanMph[i];
        final d = i < rec.spanDetails.length ? rec.spanDetails[i] : null;
        buf.writeln(
          _csvLine([
            sess,
            '${idx + 1}',
            rec.utc,
            rec.lat.toStringAsFixed(7),
            rec.lng.toStringAsFixed(7),
            '$i',
            mph?.toString() ?? '',
            d != null ? '${d.lengthM}' : '',
            d?.functionalClass?.toString() ?? '',
            d?.segmentRefShort ?? '',
          ]),
        );
      }
    }
    return LogExportPlatform.copySpanSessionCsvToDownloads(
      content: buf.toString(),
      session: session,
    );
  }
}

class _FetchRecord {
  _FetchRecord({
    required this.utc,
    required this.lat,
    required this.lng,
    required this.spanMph,
    required this.spanDetails,
  });

  final String utc;
  final double lat;
  final double lng;
  final List<int?> spanMph;
  final List<_SpanDetail> spanDetails;
}

class _SpanDetail {
  _SpanDetail({
    required this.lengthM,
    required this.functionalClass,
    required this.segmentRefShort,
  });

  final int lengthM;
  final int? functionalClass;
  final String? segmentRefShort;
}
