import '../engine/here_section_speed_model.dart';
import 'road_segment.dart';
import 'speed_limit_data.dart';

/// HERE alert fetch: limit row plus optional sticky segment and section model.
class HereAlertFetchResult {
  HereAlertFetchResult({
    required this.data,
    this.stickySegment,
    this.sectionSpeedModel,
  });

  final SpeedLimitData data;
  final RoadSegment? stickySegment;
  final HereSectionSpeedModel? sectionSpeedModel;
}
