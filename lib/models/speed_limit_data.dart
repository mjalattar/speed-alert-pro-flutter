enum ConfidenceLevel { high, medium, low }

/// Speed limit value from a provider (HERE, TomTom, Mapbox, Edge) with metadata.
class SpeedLimitData {
  const SpeedLimitData({
    required this.provider,
    this.speedLimitMph,
    this.confidence = ConfidenceLevel.medium,
    this.source = 'API',
    this.segmentKey,
    this.functionalClass,
  });

  final String provider;
  final int? speedLimitMph;
  final ConfidenceLevel confidence;
  final String source;
  final String? segmentKey;
  final int? functionalClass;

  SpeedLimitData copyWith({
    String? provider,
    int? speedLimitMph,
    ConfidenceLevel? confidence,
    String? source,
    String? segmentKey,
    int? functionalClass,
  }) {
    return SpeedLimitData(
      provider: provider ?? this.provider,
      speedLimitMph: speedLimitMph ?? this.speedLimitMph,
      confidence: confidence ?? this.confidence,
      source: source ?? this.source,
      segmentKey: segmentKey ?? this.segmentKey,
      functionalClass: functionalClass ?? this.functionalClass,
    );
  }
}
