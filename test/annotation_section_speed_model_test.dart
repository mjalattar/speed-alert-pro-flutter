import 'package:flutter_test/flutter_test.dart';
import 'package:speed_alert_pro/engine/annotation_section_speed_model.dart';
import 'package:speed_alert_pro/engine/cross_track_geometry.dart';

void main() {
  group('AnnotationSectionSpeedModel', () {
    test('fromMapboxDirectionsJson parses maxspeed and geometry', () {
      const json = '''
{"routes":[{"geometry":{"type":"LineString","coordinates":[[-95.02,29.54],[-95.021,29.541]]},"legs":[{"annotation":{"maxspeed":[{"speed":105,"unit":"km/h"},{"speed":105,"unit":"km/h"}]}}]}]}''';
      final m = AnnotationSectionSpeedModel.fromMapboxDirectionsJson(
        json,
        vehicleLat: 29.5405,
        vehicleLng: -95.0205,
        headingDegrees: 90,
      );
      expect(m, isNotNull);
      expect(m!.provider, 'Mapbox');
      expect(m.totalLengthM, greaterThan(1.0));
      final along = CrossTrackGeometry.alongPolylineMetersForMatching(
        29.5405,
        -95.0205,
        m.geometry,
        90,
      );
      final data = m.speedLimitDataAtAlong(along);
      expect(data.speedLimitMph, isNotNull);
      expect(data.speedLimitMph, closeTo(65, 2));
    });

    test('fromTomTomSnapRouteJson builds model without projectedPoints', () {
      const json = '''
{"route":[{"type":"Feature","geometry":{"type":"LineString","coordinates":[[-95.02,29.54],[-95.021,29.541]]},"properties":{"speedLimits":{"value":50,"unit":"mph"}}}]}''';
      final m = AnnotationSectionSpeedModel.fromTomTomSnapRouteJson(
        json,
        vehicleLat: 29.54,
        vehicleLng: -95.02,
        headingDegrees: 45,
      );
      expect(m, isNotNull);
      expect(m!.provider, 'TomTom');
      final along = CrossTrackGeometry.alongPolylineMetersForMatching(
        29.54,
        -95.02,
        m.geometry,
        45,
      );
      final data = m.speedLimitDataAtAlong(along);
      expect(data.speedLimitMph, 50);
    });
  });
}
