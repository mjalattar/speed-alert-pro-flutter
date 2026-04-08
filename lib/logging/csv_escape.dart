/// RFC-style CSV field escaping (quotes and doubled quotes) for debug logs.
class CsvEscape {
  CsvEscape._();

  static String escape(String? s) {
    if (s == null || s.isEmpty) return '';
    final t = s.replaceAll('"', '""');
    if (t.contains(',') || t.contains('"') || t.contains('\n') || t.contains('\r')) {
      return '"$t"';
    }
    return t;
  }
}
