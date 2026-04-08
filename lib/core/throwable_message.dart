/// Returns [Exception.message] when present, otherwise [Object.toString].
String throwableMessageOrToString(Object e) {
  try {
    final m = (e as dynamic).message;
    if (m != null) return m.toString();
  } catch (_) {}
  return e.toString();
}
