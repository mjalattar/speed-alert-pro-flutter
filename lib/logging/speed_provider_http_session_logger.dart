import 'csv_formatting.dart';
import 'log_export_platform.dart';
import 'speed_debug_log_session.dart';
import 'speed_limit_api_request_logger.dart';
import '../services/preferences_manager.dart';

/// Session-scoped HTTP rows for TomTom and for Mapbox (separate buffers; CSV export alongside HERE span logs).
class SpeedProviderHttpSessionLogger {
  SpeedProviderHttpSessionLogger._();

  static final List<_HttpRow> _tomTom = [];
  static final List<_HttpRow> _mapbox = [];

  static void clearSession() {
    _tomTom.clear();
    _mapbox.clear();
  }

  /// Record when [SpeedLimitHttpLogInterceptor] logs a TomTom or a Mapbox request (same gating as unified CSV).
  static void recordIfApplicable({
    required PreferencesManager preferencesManager,
    required String category,
    required String method,
    required String urlRedacted,
    required int httpCode,
    String note = '',
  }) {
    if (!preferencesManager.logSpeedFetchesToFile) return;
    if (!SpeedDebugLogSessionHolder.isSessionActive()) return;
    final row = _HttpRow(
      utc: SpeedLimitApiRequestLogger.utcNow(),
      method: method,
      httpCode: httpCode,
      urlRedacted: urlRedacted,
      note: note,
    );
    switch (category) {
      case 'TomTom':
        _tomTom.add(row);
        break;
      case 'Mapbox':
        _mapbox.add(row);
        break;
      default:
        break;
    }
  }

  static String _buildCsv(
    List<_HttpRow> rows,
    String provider,
    String sessionLabel,
  ) {
    final lines = <String>[
      _csvLine([
        'session',
        'provider',
        'utc_time',
        'method',
        'http_code',
        'url_redacted',
        'note',
      ]),
    ];
    for (final r in rows) {
      lines.add(
        _csvLine([
          sessionLabel,
          provider,
          r.utc,
          r.method,
          '${r.httpCode}',
          r.urlRedacted,
          r.note,
        ]),
      );
    }
    return '${lines.join('\n')}\n';
  }

  static String _csvLine(List<String> fields) =>
      fields.map((f) => CsvFormatting.escape(f)).join(',');

  static Future<String?> copyTomTomToPublicDownloads(
    SpeedDebugLogSession session,
  ) async {
    if (session == SpeedDebugLogSession.none) return null;
    if (_tomTom.isEmpty) return null;
    final content = _buildCsv(_tomTom, 'TomTom', session.name);
    return LogExportPlatform.copyProviderHttpSessionCsvToDownloads(
      content: content,
      session: session,
      provider: 'TOMTOM',
    );
  }

  static Future<String?> copyMapboxToPublicDownloads(
    SpeedDebugLogSession session,
  ) async {
    if (session == SpeedDebugLogSession.none) return null;
    if (_mapbox.isEmpty) return null;
    final content = _buildCsv(_mapbox, 'Mapbox', session.name);
    return LogExportPlatform.copyProviderHttpSessionCsvToDownloads(
      content: content,
      session: session,
      provider: 'MAPBOX',
    );
  }
}

class _HttpRow {
  _HttpRow({
    required this.utc,
    required this.method,
    required this.httpCode,
    required this.urlRedacted,
    required this.note,
  });

  final String utc;
  final String method;
  final int httpCode;
  final String urlRedacted;
  final String note;
}
