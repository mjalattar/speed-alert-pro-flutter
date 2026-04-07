/// Shared CSV field escaping for debug logs.
///
/// CSV field escaping (RFC-style quoting and doubled quotes).
class CsvFormatting {
  CsvFormatting._();

  static String escape(String? s) {
    if (s == null || s.isEmpty) return '';
    final t = s.replaceAll('"', '""');
    if (t.contains(',') || t.contains('"') || t.contains('\n') || t.contains('\r')) {
      return '"$t"';
    }
    return t;
  }
}
