/**
 * Remote HERE alert mph (matches Flutter `parseAlertFetchFromDecodedRoute`). Imported by `index.ts`.
 *
 * Mirrors Flutter `HereApiService.parseAlertFetchFromDecodedRoute` + dependencies
 * (`HereSectionSpeedModel`, `HereCrossTrackGeometry`, `PolylineDecoder`, Vincenty distance).
 * Keep in sync with: lib/services/here/api_service.dart, lib/engine/here/section_speed_model.dart,
 * lib/engine/here/cross_track_geometry.dart, lib/core/polyline_decoder.dart, lib/core/android_location_compat.dart.
 */

export type GeoCoordinate = { lat: number; lng: number };

export type HereSpanParsed = {
  offset: number;
  length: number;
  speedLimitMps: number | null;
  segmentRef: string | null;
  functionalClass: number | null;
};

const _alongEpsM = 0.5;
const _spanGapMergeEpsM = 0.5;
const _headingMismatchPenaltyMaxM = 55.0;
const earthMPerDegLat = 111320.0;
const MPS_TO_MPH = 2.23694;

// --- Android Location WGS84 Vincenty (same as Dart AndroidLocationCompat) ---

const _a = 6378137.0;
const _b = 6356752.3142;
const _f = 1 / 298.257223563;
const _maxIterations = 20;

function computeDistanceAndBearing(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
  out: number[],
): void {
  if (out.length === 0) throw new Error("results length must be at least 1");
  if (lat1 === lat2 && lon1 === lon2) {
    out[0] = 0;
    if (out.length > 1) out[1] = 0;
    if (out.length > 2) out[2] = 0;
    return;
  }

  const phi1 = (lat1 * Math.PI) / 180.0;
  const phi2 = (lat2 * Math.PI) / 180.0;
  const l = ((lon2 - lon1) * Math.PI) / 180.0;

  let lambda = l;
  let iter = 0;
  let sinSigma = 0;
  let cosSigma = 0;
  let sigma = 0;
  let sinAlpha = 0;
  let cosSqAlpha = 0;
  let cos2SigmaM = 0;

  const tanU1 = (1 - _f) * Math.tan(phi1);
  const cosU1 = 1 / Math.sqrt(1 + tanU1 * tanU1);
  const sinU1 = tanU1 * cosU1;
  const tanU2 = (1 - _f) * Math.tan(phi2);
  const cosU2 = 1 / Math.sqrt(1 + tanU2 * tanU2);
  const sinU2 = tanU2 * cosU2;

  let lambdaP = 0;
  do {
    const sinLambda = Math.sin(lambda);
    const cosLambda = Math.cos(lambda);
    sinSigma = Math.sqrt(
      (cosU2 * sinLambda) * (cosU2 * sinLambda) +
        (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda) *
          (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda),
    );
    if (sinSigma === 0) {
      out[0] = 0;
      if (out.length > 1) out[1] = 0;
      if (out.length > 2) out[2] = 0;
      return;
    }
    cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda;
    sigma = Math.atan2(sinSigma, cosSigma);
    sinAlpha = (cosU1 * cosU2 * sinLambda) / sinSigma;
    cosSqAlpha = 1 - sinAlpha * sinAlpha;
    cos2SigmaM = cosSigma - (2 * sinU1 * sinU2) / cosSqAlpha;
    if (cosSqAlpha === 0 || Number.isNaN(cos2SigmaM)) cos2SigmaM = 0;
    const c =
      (_f / 16) *
      cosSqAlpha *
      (4 + _f * (4 - 3 * cosSqAlpha));
    lambdaP = lambda;
    lambda =
      l +
      (1 - c) *
        _f *
        sinAlpha *
        (sigma +
          c *
            sinSigma *
            (cos2SigmaM +
              c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)));
    iter++;
  } while (Math.abs(lambda - lambdaP) > 1e-12 && iter < _maxIterations);

  const uSq = (cosSqAlpha * (_a * _a - _b * _b)) / (_b * _b);
  const bigA = 1 + (uSq / 16384) * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)));
  const bigB = (uSq / 1024) * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)));
  const deltaSigma =
    bigB *
    sinSigma *
    (cos2SigmaM +
      (bigB / 4) *
        (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
          (bigB / 6) *
            cos2SigmaM *
            (-3 + 4 * sinSigma * sinSigma) *
            (-3 + 4 * cos2SigmaM * cos2SigmaM)));

  const s = _b * bigA * (sigma - deltaSigma);
  out[0] = s;
  if (out.length > 1) {
    let fwdAz = Math.atan2(
      cosU2 * Math.sin(lambda),
      cosU1 * sinU2 - sinU1 * cosU2 * Math.cos(lambda),
    );
    fwdAz = (fwdAz * 180) / Math.PI;
    out[1] = (fwdAz + 360) % 360;
  }
  if (out.length > 2) {
    let revAz = Math.atan2(
      cosU1 * Math.sin(lambda),
      -sinU1 * cosU2 + cosU1 * sinU2 * Math.cos(lambda),
    );
    revAz = (revAz * 180) / Math.PI;
    out[2] = (revAz + 360) % 360;
  }
}

export function distanceBetweenMeters(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const out = [0];
  computeDistanceAndBearing(lat1, lon1, lat2, lon2, out);
  return out[0];
}

// --- geo_bearing.dart ---

export function smallestBearingDeltaDeg(a: number, b: number): number {
  let d = Math.abs(a - b) % 360.0;
  if (d > 180.0) d = 360.0 - d;
  return d;
}

export function bearingDeg(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number,
): number {
  const p1 = (lat1 * Math.PI) / 180.0;
  const p2 = (lat2 * Math.PI) / 180.0;
  const dLng = ((lng2 - lng1) * Math.PI) / 180.0;
  const y = Math.sin(dLng) * Math.cos(p2);
  const x =
    Math.cos(p1) * Math.sin(p2) -
    Math.sin(p1) * Math.cos(p2) * Math.cos(dLng);
  const brng = Math.atan2(y, x) * (180.0 / Math.PI);
  return (brng + 360.0) % 360.0;
}

function headingPenaltyScale(headingAccuracyDeg: number | null | undefined): number {
  if (
    headingAccuracyDeg == null ||
    !Number.isFinite(headingAccuracyDeg) ||
    headingAccuracyDeg <= 0
  ) {
    return 1.0;
  }
  return 1.0 / (1.0 + Math.min(headingAccuracyDeg / 40.0, 1.75));
}

// --- PolylineDecoder (HERE flexible polyline) ---

export function decodeFlexiblePolyline(encoded: string): GeoCoordinate[] {
  const results: GeoCoordinate[] = [];
  let index = 0;

  function decodeUnsignedVarint(): number {
    let result = 0;
    let shift = 0;
    while (index < encoded.length) {
      const char = encoded[index++];
      const value = charValue(char);
      result |= (value & 31) << shift;
      if ((value & 32) === 0) break;
      shift += 5;
    }
    return result;
  }

  function decodeSignedVarint(): number {
    const unsigned = decodeUnsignedVarint();
    return (unsigned & 1) !== 0 ? ~(unsigned >> 1) : (unsigned >> 1);
  }

  if (!encoded.length) return results;

  decodeUnsignedVarint(); // version
  const bitmask = decodeUnsignedVarint();
  const precision = bitmask & 15;
  const thirdDim = (bitmask >> 4) & 7;
  const multiplier = 10 ** precision;

  let lastLat = 0;
  let lastLng = 0;
  let lastZ = 0;

  while (index < encoded.length) {
    lastLat += decodeSignedVarint();
    lastLng += decodeSignedVarint();
    results.push({
      lat: lastLat / multiplier,
      lng: lastLng / multiplier,
    });
    if (thirdDim !== 0) {
      lastZ += decodeSignedVarint();
    }
  }
  return results;
}

function charValue(char: string): number {
  if (!char.length) return 0;
  const c = char.charCodeAt(0);
  if (c >= 65 && c <= 90) return c - 65;
  if (c >= 97 && c <= 122) return c - 97 + 26;
  if (c >= 48 && c <= 57) return c - 48 + 52;
  if (char === "-") return 62;
  if (char === "_") return 63;
  return 0;
}

// --- cross_track_geometry (matching path used by parseAlertFetch; no tie-break options on Edge) ---

function projectOntoSegmentMeters(
  pLat: number,
  pLng: number,
  aLat: number,
  aLng: number,
  bLat: number,
  bLng: number,
): { t: number; cLat: number; cLng: number } {
  const lat0 = (Math.PI * (aLat + bLat)) / 360.0;
  const scale = Math.cos(lat0) * earthMPerDegLat;
  const ax = aLng * scale;
  const bx = bLng * scale;
  const px = pLng * scale;
  const ay = aLat * earthMPerDegLat;
  const by = bLat * earthMPerDegLat;
  const py = pLat * earthMPerDegLat;
  const abx = bx - ax;
  const aby = by - ay;
  const apx = px - ax;
  const apy = py - ay;
  const ab2 = abx * abx + aby * aby;
  const t = ab2 < 1e-9 ? 0.0 : Math.min(1, Math.max(0, (apx * abx + apy * aby) / ab2));
  const cx = ax + t * abx;
  const cy = ay + t * aby;
  const cLat = cy / earthMPerDegLat;
  const cLng = cx / scale;
  return { t, cLat, cLng };
}

type PolylineProjection = {
  alongMeters: number;
  crossTrackMeters: number;
  segmentIndex: number;
  segmentBearingDeg: number;
};

function alongPolylineMeters(
  userLat: number,
  userLng: number,
  geometry: GeoCoordinate[],
): number {
  if (geometry.length < 2) return 0;
  let bestAlong = 0;
  let bestLat = Infinity;
  let cum = 0;
  for (let i = 0; i < geometry.length - 1; i++) {
    const a = geometry[i];
    const b = geometry[i + 1];
    const segLen = distanceBetweenMeters(a.lat, a.lng, b.lat, b.lng);
    if (segLen < 0.5) continue;
    const proj = projectOntoSegmentMeters(
      userLat, userLng, a.lat, a.lng, b.lat, b.lng,
    );
    const cLat = proj.cLat;
    const cLng = proj.cLng;
    const latDist = distanceBetweenMeters(userLat, userLng, cLat, cLng);
    const along = cum + proj.t * segLen;
    if (latDist < bestLat) {
      bestLat = latDist;
      bestAlong = along;
    }
    cum += segLen;
  }
  return bestAlong;
}

function projectOntoPolylineForMatching(
  userLat: number,
  userLng: number,
  geometry: GeoCoordinate[],
  userHeadingDeg: number | null | undefined,
  matchingOptions?: {
    headingAccuracyDegrees?: number | null;
  } | null,
): PolylineProjection | null {
  if (geometry.length < 2) return null;
  const useHeading = userHeadingDeg != null && Number.isFinite(userHeadingDeg);
  const headingPenScale = headingPenaltyScale(
    matchingOptions?.headingAccuracyDegrees ?? null,
  );
  const n = geometry.length - 1;
  let bestAlong = 0;
  let bestCross = Infinity;
  let bestScore = Infinity;
  let bestSeg = 0;
  let cum = 0;
  for (let i = 0; i < n; i++) {
    const a = geometry[i];
    const b = geometry[i + 1];
    const segLen = distanceBetweenMeters(a.lat, a.lng, b.lat, b.lng);
    if (segLen < 0.5) continue;
    const proj = projectOntoSegmentMeters(
      userLat, userLng, a.lat, a.lng, b.lat, b.lng,
    );
    const t = proj.t;
    const cLat = proj.cLat;
    const cLng = proj.cLng;
    const latDist = distanceBetweenMeters(userLat, userLng, cLat, cLng);
    const along = cum + t * segLen;
    const brg = bearingDeg(a.lat, a.lng, b.lat, b.lng);
    let score: number;
    if (useHeading) {
      const delta = Math.min(
        180.0,
        Math.max(0.0, smallestBearingDeltaDeg(userHeadingDeg!, brg)),
      );
      const penalty =
        Math.min(1.75, delta / 90.0) *
        _headingMismatchPenaltyMaxM *
        headingPenScale;
      score = latDist + penalty;
    } else {
      score = latDist;
    }
    if (
      score < bestScore - 1e-6 ||
      (Math.abs(score - bestScore) <= 1e-6 && latDist < bestCross)
    ) {
      bestScore = score;
      bestCross = latDist;
      bestAlong = along;
      bestSeg = i;
    }
    cum += segLen;
  }
  const a = geometry[bestSeg];
  const b = geometry[bestSeg + 1];
  const brg = bearingDeg(a.lat, a.lng, b.lat, b.lng);
  return {
    alongMeters: bestAlong,
    crossTrackMeters: bestCross,
    segmentIndex: bestSeg,
    segmentBearingDeg: brg,
  };
}

function alongPolylineMetersForMatching(
  userLat: number,
  userLng: number,
  geometry: GeoCoordinate[],
  userHeadingDeg: number | null | undefined,
): number {
  const p = projectOntoPolylineForMatching(
    userLat,
    userLng,
    geometry,
    userHeadingDeg,
    null,
  );
  return p != null ? p.alongMeters : alongPolylineMeters(userLat, userLng, geometry);
}

// --- HereSectionSpeedModel ---

type SpanSlice = { fromM: number; toM: number; span: HereSpanParsed };

function vertexPrefixDistancesMeters(geometry: GeoCoordinate[]): number[] {
  const n = geometry.length;
  const d = new Array<number>(n).fill(0);
  for (let i = 1; i < n; i++) {
    d[i] =
      d[i - 1] +
      distanceBetweenMeters(
        geometry[i - 1].lat,
        geometry[i - 1].lng,
        geometry[i].lat,
        geometry[i].lng,
      );
  }
  return d;
}

function spanToMeterRangeEdges(
  span: HereSpanParsed,
  vertexCount: number,
  prefix: number[],
): [number, number] | null {
  const lastV = vertexCount - 1;
  const startV = Math.min(Math.max(span.offset, 0), lastV);
  let edges = span.length;
  if (edges < 1) edges = 1;
  const endV = Math.min(Math.max(startV + edges, startV + 1), lastV);
  const fromM = prefix[startV];
  const toM = prefix[endV];
  if (toM <= fromM + 1e-6) return null;
  return [fromM, toM];
}

function spanToMeterRangeVertexCount(
  span: HereSpanParsed,
  vertexCount: number,
  prefix: number[],
): [number, number] | null {
  const lastV = vertexCount - 1;
  const startV = Math.min(Math.max(span.offset, 0), lastV);
  let vCount = span.length < 1 ? 1 : span.length;
  let endV = Math.min(Math.max(startV + vCount - 1, startV), lastV);
  if (endV === startV && startV < lastV) endV = startV + 1;
  const fromM = prefix[startV];
  const toM = prefix[endV];
  if (toM <= fromM + 1e-6) return null;
  return [fromM, toM];
}

function buildSpanSlices(
  spans: HereSpanParsed[],
  vertexCount: number,
  prefix: number[],
  edgesMode: boolean,
): SpanSlice[] {
  const out: SpanSlice[] = [];
  for (const sp of spans) {
    const range = edgesMode
      ? spanToMeterRangeEdges(sp, vertexCount, prefix)
      : spanToMeterRangeVertexCount(sp, vertexCount, prefix);
    if (range != null) {
      out.push({ fromM: range[0], toM: range[1], span: sp });
    }
  }
  return out;
}

function normalizeSpanSlices(slices: SpanSlice[], totalM: number): SpanSlice[] {
  if (slices.length === 0) return [];
  const sorted = [...slices].sort((a, b) => a.fromM - b.fromM);
  const out: SpanSlice[] = [];
  let prevTo = 0.0;
  for (const s of sorted) {
    let from = Math.min(Math.max(s.fromM, 0.0), totalM);
    const to = Math.min(Math.max(s.toM, 0.0), totalM);
    if (from < prevTo) from = prevTo;
    if (from >= to) continue;
    if (out.length > 0 && from > prevTo + _spanGapMergeEpsM) {
      const last = out.pop()!;
      out.push({ fromM: last.fromM, toM: from, span: last.span });
    }
    out.push({ fromM: from, toM: to, span: s.span });
    prevTo = to;
  }
  if (out.length > 0 && out[out.length - 1].toM < totalM - 0.1) {
    const last = out.pop()!;
    out.push({ fromM: last.fromM, toM: totalM, span: last.span });
  }
  return out;
}

function buildSectionSpeedModel(
  spans: HereSpanParsed[],
  geometry: GeoCoordinate[],
): { slices: SpanSlice[]; totalLengthM: number } | null {
  if (geometry.length < 2 || spans.length === 0) return null;
  const ordered = [...spans].sort((a, b) => a.offset - b.offset);
  const prefix = vertexPrefixDistancesMeters(geometry);
  const total = prefix[prefix.length - 1];
  if (total < 1.0) return null;
  const n = geometry.length;
  let slices = buildSpanSlices(ordered, n, prefix, true);
  if (slices.length === 0) return null;
  let coverageM = slices.map((s) => s.toM).reduce((a, b) => (a > b ? a : b));
  if (coverageM < total * 0.85) {
    const alt = buildSpanSlices(ordered, n, prefix, false);
    const altCover = alt.length === 0
      ? 0.0
      : alt.map((s) => s.toM).reduce((a, b) => (a > b ? a : b));
    if (alt.length > 0 && altCover > coverageM + 5.0) {
      slices = alt;
    }
  }
  const normalized = normalizeSpanSlices(slices, total);
  if (normalized.length === 0) return null;
  return { slices: normalized, totalLengthM: total };
}

function spanForAlong(slices: SpanSlice[], along: number): HereSpanParsed | null {
  if (slices.length === 0) return null;
  let containing = -1;
  for (let i = 0; i < slices.length; i++) {
    const sl = slices[i];
    if (along >= sl.fromM - _alongEpsM && along < sl.toM + _alongEpsM) {
      containing = i;
      break;
    }
  }
  if (containing < 0) {
    for (let i = slices.length - 1; i >= 0; i--) {
      if (slices[i].fromM <= along + _alongEpsM) {
        containing = i;
        break;
      }
    }
  }
  if (containing < 0) return slices[0].span;

  let j = containing;
  while (j >= 0 && slices[j].span.speedLimitMps == null) j--;
  if (j >= 0) return slices[j].span;
  j = containing;
  while (j < slices.length && slices[j].span.speedLimitMps == null) j++;
  return j < slices.length ? slices[j].span : slices[containing].span;
}

function mphFromSpan(span: HereSpanParsed | null): number | null {
  if (span?.speedLimitMps == null) return null;
  return Math.round(span.speedLimitMps * MPS_TO_MPH);
}

function speedLimitMphAtAlong(
  slices: SpanSlice[],
  totalLengthM: number,
  alongMeters: number,
): number | null {
  const along = Math.min(
    Math.max(alongMeters, 0.0),
    totalLengthM + _alongEpsM,
  );
  const span = spanForAlong(slices, along);
  return mphFromSpan(span);
}

function routingIntField(v: unknown): number {
  if (v == null) return 0;
  if (typeof v === "number" && Number.isFinite(v)) return Math.trunc(v);
  if (typeof v === "string") {
    const p = parseInt(v.trim(), 10);
    return Number.isFinite(p) ? p : 0;
  }
  return 0;
}

function routingSpeedLimitMps(v: unknown): number | null {
  if (v == null) return null;
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const p = parseFloat(v.trim());
    return Number.isFinite(p) ? p : null;
  }
  return null;
}

export function hereSpanFromRoutingJson(m: Record<string, unknown>): HereSpanParsed {
  return {
    offset: routingIntField(m["offset"]),
    length: routingIntField(m["length"]),
    speedLimitMps: routingSpeedLimitMps(m["speedLimit"]),
    segmentRef: typeof m["segmentRef"] === "string" ? m["segmentRef"] : null,
    functionalClass: typeof m["functionalClass"] === "number"
      ? m["functionalClass"]
      : null,
  };
}

function pickSpeedSpan(spans: HereSpanParsed[]): HereSpanParsed | null {
  for (const s of spans) {
    if (s.speedLimitMps != null) return s;
  }
  return null;
}

/**
 * Same mph as Flutter `parseAlertFetchFromDecodedRoute` for the first route / first section.
 */
export function parseAlertMphFromHereRoutesJson(
  root: unknown,
  lat: number,
  lng: number,
  headingDegrees: number | null | undefined,
): number | null {
  if (!root || typeof root !== "object") return null;
  const routes = (root as { routes?: unknown }).routes;
  if (!Array.isArray(routes) || routes.length === 0) return null;
  const route = routes[0] as { sections?: unknown };
  const sections = route.sections;
  if (!Array.isArray(sections) || sections.length === 0) return null;
  const section = sections[0] as {
    polyline?: unknown;
    spans?: unknown;
  };
  const poly = typeof section.polyline === "string" ? section.polyline : "";
  const geometry = decodeFlexiblePolyline(poly);
  const spanList = Array.isArray(section.spans) ? section.spans : [];
  const spans: HereSpanParsed[] = spanList.map((e) =>
    hereSpanFromRoutingJson(e as Record<string, unknown>)
  );

  let sectionModel: { slices: SpanSlice[]; totalLengthM: number } | null = null;
  if (geometry.length >= 2 && spans.length > 0) {
    sectionModel = buildSectionSpeedModel(spans, geometry);
  }

  let effectiveHeading: number | null =
    headingDegrees != null && Number.isFinite(headingDegrees)
      ? headingDegrees
      : null;
  if (
    (effectiveHeading == null || !Number.isFinite(effectiveHeading)) &&
    geometry.length >= 2
  ) {
    const d0 = distanceBetweenMeters(
      lat,
      lng,
      geometry[0].lat,
      geometry[0].lng,
    );
    if (d0 < 40.0) {
      effectiveHeading = bearingDeg(
        geometry[0].lat,
        geometry[0].lng,
        geometry[1].lat,
        geometry[1].lng,
      );
    }
  }

  const alongVehicle = geometry.length >= 2
    ? alongPolylineMetersForMatching(lat, lng, geometry, effectiveHeading)
    : 0;

  if (sectionModel != null) {
    const atAlong = speedLimitMphAtAlong(
      sectionModel.slices,
      sectionModel.totalLengthM,
      alongVehicle,
    );
    if (atAlong != null) return atAlong;
    const fb = pickSpeedSpan(spans);
    return mphFromSpan(fb);
  }
  const fb = pickSpeedSpan(spans);
  return mphFromSpan(fb);
}
