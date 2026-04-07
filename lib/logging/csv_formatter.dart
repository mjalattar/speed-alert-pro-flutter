/// Shared CSV field escaping for debug logs.
///
/// Kotlin [com.speedalertpro.CsvFormatting].
// VERIFIED: 1:1 Logic match with Kotlin (quote doubling, wrap rules).
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
