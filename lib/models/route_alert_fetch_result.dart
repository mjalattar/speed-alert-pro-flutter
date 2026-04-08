import '../engine/here/section_speed_model.dart';
import 'road_segment.dart';
import 'speed_limit_data.dart';

/// Result of a primary route/alert fetch (HERE Router or Remote Edge).
class RouteAlertFetchResult {
  RouteAlertFetchResult({
    required this.data,
    this.stickySegment,
    this.sectionSpeedModel,
  });

  final SpeedLimitData data;
  final RoadSegment? stickySegment;
  final HereSectionSpeedModel? sectionSpeedModel;
}
