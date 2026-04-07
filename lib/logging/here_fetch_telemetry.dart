/// Kotlin [SpeedFetchDebugLogger.HereFetchTelemetry].
class HereFetchTelemetry {
  const HereFetchTelemetry({
    required this.requestUtc,
    required this.responseUtc,
    this.responseSource,
    this.responseConfidence,
    this.functionalClass,
    this.segmentCacheZoneCount,
    this.segmentCacheRouteLenM,
    this.apiError,
  });

  final String requestUtc;
  final String responseUtc;
  final String? responseSource;
  final String? responseConfidence;
  final int? functionalClass;
  final int? segmentCacheZoneCount;
  final double? segmentCacheRouteLenM;
  final String? apiError;
}
