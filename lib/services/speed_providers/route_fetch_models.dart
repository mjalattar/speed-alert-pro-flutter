import '../../engine/annotation_section_speed_model.dart';
import '../../models/speed_limit_data.dart';

/// Result of a single-provider route fetch (TomTom Snap or Mapbox Directions): limit + optional section model.
class RouteFetchOutcome {
  RouteFetchOutcome(this.data, this.sectionModel);

  final SpeedLimitData data;
  final AnnotationSectionSpeedModel? sectionModel;
}
