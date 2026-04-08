import 'package:geolocator/geolocator.dart';

import '../../engine/here/cross_track_geometry.dart';
import '../../engine/here/section_speed_model.dart';
import '../../engine/shared/section_walk_along_continuity.dart';
import '../../models/road_segment.dart';
import 'route_primary_tick_types.dart';

/// Remote primary: section-walk along route geometry from Remote/Edge responses.
/// Kept in a separate file from [here_primary_tick] so Edge-side behavior can diverge.
RoutePrimarySectionWalkResult remotePrimaryTrySectionWalk({
  required Position location,
  required HerePolylineMatchingOptions hereMatchOpts,
  required double? headingForPolyline,
  required HereSectionSpeedModel? routeModel,
  required SectionWalkAlongContinuity continuity,
}) {
  if (routeModel == null || routeModel.isExpired()) {
    return RoutePrimarySectionWalkContinue();
  }
  final hereOpts = hereMatchOpts.withEdgeMph(routeModel.mphHintsPerEdge());
  final proj = HereCrossTrackGeometry.projectOntoPolylineForMatching(
    location.latitude,
    location.longitude,
    routeModel.geometry,
    headingForPolyline,
    matchingOptions: hereOpts,
  );
  if (proj == null ||
      !HereCrossTrackGeometry.isSectionWalkProjectionValid(
        proj,
        routeModel.geometry,
        headingForPolyline,
        matchingOptions: hereOpts,
      )) {
    return RoutePrimarySectionWalkInvalidate();
  }
  final alongRaw = proj.alongMeters;
  final along = continuity.clampAlong(alongRaw, location);
  final resolved = routeModel.speedLimitDataAtAlong(along);
  final mph = resolved.speedLimitMph;
  if (mph != null) {
    return RoutePrimarySectionWalkStop(
      RoutePrimaryApplySnapshot(
        rawMph: mph,
        segmentKey: resolved.segmentKey,
        functionalClass: resolved.functionalClass,
        resolvePath: 'section_walk',
      ),
    );
  }
  return RoutePrimarySectionWalkContinue();
}

/// Remote primary: sticky segment from Remote fetch cache.
RoutePrimaryApplySnapshot? remotePrimaryTrySticky({
  required Position location,
  required double? headingForPolyline,
  required RoadSegment? sticky,
}) {
  if (sticky == null ||
      sticky.isExpired() ||
      !HereCrossTrackGeometry.isUserOnSegment(
        location.latitude,
        location.longitude,
        sticky,
        headingForPolyline,
      )) {
    return null;
  }
  return RoutePrimaryApplySnapshot(
    rawMph: sticky.speedLimitMph.round(),
    segmentKey: sticky.linkId,
    functionalClass: sticky.functionalClass,
    resolvePath: 'sticky',
  );
}
