import '../services/preferences_manager.dart';
import 'log_export_platform.dart';
import 'speed_debug_log_session.dart';
import 'speed_limit_api_request_logger.dart';

/// Kotlin [HereSpanFetchSessionLogger] — per-span mph from local HERE JSON.
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
    if (!preferencesManager.logSpeedFetchesToFile) return;
    final spanMph = _spanSpeedMphList(routeRoot);
    if (spanMph.isEmpty) return;
    _fetches.add(
      _FetchRecord(
        utc: SpeedLimitApiRequestLogger.utcNow(),
        lat: lat,
        lng: lng,
        spanMph: spanMph,
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

  static Future<String?> copySessionToPublicDownloads(
    SpeedDebugLogSession session,
  ) async {
    if (session == SpeedDebugLogSession.none) return null;
    if (_fetches.isEmpty) return null;
    final buf = StringBuffer()
      ..writeln('Speed Alert Pro — HERE routing span speeds (per fetch)')
      ..writeln('Session: ${session.name}')
      ..writeln('Fetch count: ${_fetches.length}')
      ..writeln();
    for (var idx = 0; idx < _fetches.length; idx++) {
      final rec = _fetches[idx];
      buf.writeln('--- Fetch #${idx + 1} ---');
      buf.writeln('utc: ${rec.utc}');
      buf.writeln(
        'lat: ${rec.lat.toStringAsFixed(7)}  lng: ${rec.lng.toStringAsFixed(7)}',
      );
      buf.writeln('span_count: ${rec.spanMph.length}');
      for (var i = 0; i < rec.spanMph.length; i++) {
        final mph = rec.spanMph[i];
        buf.writeln('  span[$i]: ${mph != null ? '$mph mph' : '(no speed limit from API)'}');
      }
      buf.writeln();
    }
    return LogExportPlatform.copySpanSessionTxtToDownloads(
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
  });

  final String utc;
  final double lat;
  final double lng;
  final List<int?> spanMph;
}
