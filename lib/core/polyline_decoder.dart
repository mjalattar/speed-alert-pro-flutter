import 'dart:math' as math;

import '../engine/geo_coordinate.dart';

/// Standard HERE Flexible Polyline Decoder.
/// Decodes the compressed polyline format returned by HERE Routing API v8.
/// Based on official specification: https://github.com/heremaps/flexible-polyline
///
/// Kotlin [com.speedalertpro.PolylineDecoder] — returns [GeoCoordinate] instead of [android.location.Location].
// VERIFIED: 1:1 Logic match with Kotlin (varint decode, bitmask, multiplier, lat/lng/z order).
class PolylineDecoder {
  PolylineDecoder._();

  static List<GeoCoordinate> decode(String encoded) {
    final results = <GeoCoordinate>[];
    var index = 0;

    int decodeUnsignedVarint() {
      var result = 0;
      var shift = 0;
      while (index < encoded.length) {
        final char = encoded[index++];
        final value = _charValue(char);
        result |= (value & 31) << shift;
        if ((value & 32) == 0) break;
        shift += 5;
      }
      return result;
    }

    int decodeSignedVarint() {
      final unsigned = decodeUnsignedVarint();
      return (unsigned & 1) != 0 ? ~(unsigned >> 1) : (unsigned >> 1);
    }

    if (encoded.isEmpty) return results;

    // Format version (Kotlin stores in `version`; not used after decode).
    // ignore: unused_local_variable
    final version = decodeUnsignedVarint();

    final bitmask = decodeUnsignedVarint();
    final precision = bitmask & 15;
    final thirdDim = (bitmask >> 4) & 7;

    final multiplier = math.pow(10.0, precision).toDouble();

    var lastLat = 0;
    var lastLng = 0;
    // Kotlin `lastZ` — accumulated third dimension; not read (same as Kotlin).
    // ignore: unused_local_variable
    var lastZ = 0;

    while (index < encoded.length) {
      lastLat += decodeSignedVarint();
      lastLng += decodeSignedVarint();

      results.add(
        GeoCoordinate(
          lastLat.toDouble() / multiplier,
          lastLng.toDouble() / multiplier,
        ),
      );

      if (thirdDim != 0) {
        lastZ += decodeSignedVarint();
      }
    }

    return results;
  }

  static int _charValue(String char) {
    if (char.isEmpty) return 0;
    final c = char.codeUnitAt(0);
    if (c >= 65 && c <= 90) return c - 65;
    if (c >= 97 && c <= 122) return c - 97 + 26;
    if (c >= 48 && c <= 57) return c - 48 + 52;
    if (char == '-') return 62;
    if (char == '_') return 63;
    return 0;
  }
}
