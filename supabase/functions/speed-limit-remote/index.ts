// Supabase Edge `speed-limit-remote`: HERE Routes v8 + optional `speed_limit_cache` (auth + trial/RevenueCat gate).
// Secrets: HERE_API_KEY; optional REVENUECAT_SECRET_API_KEY, RC_ENTITLEMENT_ID, CACHE_TTL_HOURS

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { corsHeaders, verifyJwt } from "../_shared/auth.ts";
import { parseAlertMphFromHereRoutesJson } from "./speed_limit_remote.ts";

async function verifySubscriptionAccess(
  admin: ReturnType<typeof createClient>,
  userId: string,
): Promise<{ allowed: boolean; error: Response | null }> {
  const { data: profile, error: profErr } = await admin
    .from("profiles")
    .select("trial_ends_at, subscription_active, subscription_checked_at")
    .eq("id", userId)
    .maybeSingle();

  if (profErr) {
    console.error("profiles read", profErr);
  }

  // Check trial
  const trialEndsIso: string | null =
    profile?.trial_ends_at != null ? String(profile.trial_ends_at) : null;
  if (
    trialEndsIso != null &&
    !Number.isNaN(Date.parse(trialEndsIso)) &&
    Date.parse(trialEndsIso) > Date.now()
  ) {
    return { allowed: true, error: null };
  }

  // Check subscription_active from auth-check + staleness
  if (profile?.subscription_active === true) {
    const checkedAt = profile.subscription_checked_at;
    if (checkedAt != null) {
      const ageMs = Date.now() - Date.parse(String(checkedAt));
      // Allow if checked within the last 24 hours
      if (!Number.isNaN(ageMs) && ageMs < 24 * 3600_000) {
        return { allowed: true, error: null };
      }
    }
  }

  return {
    allowed: false,
    error: new Response(
      JSON.stringify({
        error: "subscription_required",
        message:
          "Free trial ended or no active subscription. Please re-open the app to verify access, or subscribe in the app.",
      }),
      { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    ),
  };
}

type Body = {
  lat: number;
  lng: number;
  dest_lat?: number | null;
  dest_lng?: number | null;
  kind?: "alert" | "route";
  heading_degrees?: number | null;
};

const HERE_ALERT_ROUTE_LEAD_METERS = 1000;

/** Bump when alert mph extraction / cache shape changes so stale rows are not reused. */
const HERE_ALERT_CACHE_RULE = "2026-04-neighbors-segref";

/** Origin coordinates floored to this many decimal places for cache keys. */
const ORIGIN_DECIMALS = 3; // ~111 m cell

/** Heading bucket width (degrees). 360 / 30 = 12 compass points. */
const HEADING_BUCKET_DEGREES = 30;

function cacheFloor(n: number, decimals: number): number {
  const f = 10 ** decimals;
  return Math.floor(n * f) / f;
}

function headingBucket(headingDeg: number | null): number {
  if (headingDeg != null && Number.isFinite(headingDeg)) {
    return Math.floor((((headingDeg % 360) + 360) % 360) / HEADING_BUCKET_DEGREES) * HEADING_BUCKET_DEGREES;
  }
  return 0;
}

function cacheKeyAlert(
  lat: number,
  lng: number,
  headingDeg: number | null,
  hasExplicitDest: boolean,
  destLat: number,
  destLng: number,
): string {
  const origin = `${cacheFloor(lat, ORIGIN_DECIMALS)},${cacheFloor(lng, ORIGIN_DECIMALS)}`;
  if (hasExplicitDest) {
    return `${origin}|${cacheFloor(destLat, ORIGIN_DECIMALS)},${cacheFloor(destLng, ORIGIN_DECIMALS)}|${HERE_ALERT_CACHE_RULE}`;
  }
  const h = headingBucket(headingDeg);
  return `${origin}|h${h}|${HERE_ALERT_CACHE_RULE}`;
}

/** Generate cache keys for the 3×3 neighborhood around (lat, lng) + same heading bucket. */
function neighborCacheKeys(
  lat: number,
  lng: number,
  headingDeg: number | null,
  hasExplicitDest: boolean,
  destLat: number,
  destLng: number,
): string[] {
  const keys: string[] = [];
  const step = 1 / (10 ** ORIGIN_DECIMALS); // ~0.001 degrees ≈ 111 m
  const h = headingBucket(headingDeg);
  for (let dLat = -1; dLat <= 1; dLat++) {
    for (let dLng = -1; dLng <= 1; dLng++) {
      const nLat = cacheFloor(lat, ORIGIN_DECIMALS) + dLat * step;
      const nLng = cacheFloor(lng, ORIGIN_DECIMALS) + dLng * step;
      if (hasExplicitDest) {
        keys.push(`${nLat},${nLng}|${cacheFloor(destLat, ORIGIN_DECIMALS)},${cacheFloor(destLng, ORIGIN_DECIMALS)}|${HERE_ALERT_CACHE_RULE}`);
      } else {
        keys.push(`${nLat},${nLng}|h${h}|${HERE_ALERT_CACHE_RULE}`);
      }
    }
  }
  return keys;
}

/** Stable segment key from a HERE segmentRef (strip direction suffix). */
function stableSegmentKey(segmentRef: string | null | undefined): string | null {
  if (!segmentRef || typeof segmentRef !== "string") return null;
  const trimmed = segmentRef.trim();
  if (!trimmed) return null;
  const stableRef = trimmed.split("#")[0].trim();
  if (!stableRef) return null;
  return `seg:${stableRef}|${HERE_ALERT_CACHE_RULE}`;
}

async function fetchHereRoutesJson(
  hereKey: string,
  origin: string,
  destination: string,
): Promise<unknown> {
  const u = new URL("https://router.hereapi.com/v8/routes");
  u.searchParams.set("transportMode", "car");
  u.searchParams.set("origin", origin);
  u.searchParams.set("destination", destination);
  u.searchParams.set("routingMode", "short");
  u.searchParams.set("return", "polyline");
  u.searchParams.set("spans", "speedLimit,segmentRef,functionalClass");
  u.searchParams.set("apiKey", hereKey);
  const res = await fetch(u.toString());
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`HERE HTTP ${res.status}: ${text.slice(0, 400)}`);
  }
  return JSON.parse(text);
}

function offsetLatLngMeters(
  lat: number,
  lng: number,
  bearingDeg: number,
  distanceM: number,
): [number, number] {
  const br = (bearingDeg * Math.PI) / 180;
  const rEarth = 6378137;
  const lat1 = (lat * Math.PI) / 180;
  const lon1 = (lng * Math.PI) / 180;
  const ang = distanceM / rEarth;
  const lat2 = Math.asin(
    Math.sin(lat1) * Math.cos(ang) +
      Math.cos(lat1) * Math.sin(ang) * Math.cos(br),
  );
  const lon2 = lon1 +
    Math.atan2(
      Math.sin(br) * Math.sin(ang) * Math.cos(lat1),
      Math.cos(ang) - Math.sin(lat1) * Math.sin(lat2),
    );
  return [(lat2 * 180) / Math.PI, (lon2 * 180) / Math.PI];
}

async function resolveHereAlertPayload(
  admin: ReturnType<typeof createClient>,
  hereKey: string,
  lat: number,
  lng: number,
  dLat: number | null,
  dLng: number | null,
  headingDeg: number | null,
): Promise<{ speed_limit_mph: number | null; cached: boolean; source: string }> {
  const origin = `${lat},${lng}`;
  const hasExplicitDest = dLat != null && dLng != null && Number.isFinite(dLat) && Number.isFinite(dLng);
  let destLat: number;
  let destLng: number;
  if (hasExplicitDest) {
    destLat = dLat!;
    destLng = dLng!;
  } else if (headingDeg != null && Number.isFinite(headingDeg)) {
    [destLat, destLng] = offsetLatLngMeters(
      lat,
      lng,
      headingDeg,
      HERE_ALERT_ROUTE_LEAD_METERS,
    );
  } else {
    destLat = lat + 0.00001;
    destLng = lng;
  }
  const destination = `${destLat},${destLng}`;

  const exactKey = cacheKeyAlert(lat, lng, headingDeg, hasExplicitDest, destLat, destLng);
  const neighborKeys = neighborCacheKeys(lat, lng, headingDeg, hasExplicitDest, destLat, destLng);
  const ttlHours = Number(Deno.env.get("CACHE_TTL_HOURS") ?? "24") || 24;
  const now = Date.now();

  // Tier 1: probe exact key + 8 neighbor cells in one query
  const { data: cachedRows, error: cacheReadErr } = await admin
    .from("speed_limit_cache")
    .select("cache_key, speed_limit_mph, expires_at")
    .in("cache_key", neighborKeys);

  if (!cacheReadErr && cachedRows && cachedRows.length > 0) {
    // Prefer exact key hit, then any non-expired neighbor hit
    let exactHit: { speed_limit_mph: number; expires_at: string } | null = null;
    let neighborHit: { speed_limit_mph: number; expires_at: string } | null = null;
    for (const row of cachedRows) {
      const exp = Date.parse(String(row.expires_at));
      if (Number.isNaN(exp) || exp <= now) continue;
      if (row.speed_limit_mph == null) continue;
      if (row.cache_key === exactKey) {
        exactHit = row;
      } else if (!neighborHit) {
        neighborHit = row;
      }
    }
    const hit = exactHit ?? neighborHit;
    if (hit) {
      // If we found a neighbor hit but not an exact hit, backfill the exact key
      if (!exactHit && neighborHit) {
        const expiresAt = new Date(now + ttlHours * 3600_000).toISOString();
        admin.from("speed_limit_cache").upsert(
          {
            cache_key: exactKey,
            speed_limit_mph: neighborHit.speed_limit_mph,
            fetched_at: new Date(now).toISOString(),
            expires_at: expiresAt,
          },
          { onConflict: "cache_key" },
        ).then(() => {}).catch(() => {});
      }
      return {
        speed_limit_mph: hit.speed_limit_mph,
        cached: true,
        source: exactHit ? "cache" : "cache_neighbor",
      };
    }
  }

  // Cache miss — call HERE API
  const hereJson = await fetchHereRoutesJson(
    hereKey,
    origin,
    destination,
  );
  const parsed = parseAlertMphFromHereRoutesJson(
    hereJson,
    lat,
    lng,
    headingDeg,
  );
  const mph = parsed.mph;
  const segRef = parsed.segmentRef;

  if (mph != null) {
    const expiresAt = new Date(now + ttlHours * 3600_000).toISOString();
    const cacheWrites: Promise<unknown>[] = [];

    // Write Tier 1: geo+heading cache key
    cacheWrites.push(
      admin.from("speed_limit_cache").upsert(
        {
          cache_key: exactKey,
          speed_limit_mph: mph,
          fetched_at: new Date(now).toISOString(),
          expires_at: expiresAt,
        },
        { onConflict: "cache_key" },
      ),
    );

    // Write Tier 2: segmentRef dedup key
    const segKey = stableSegmentKey(segRef);
    if (segKey) {
      cacheWrites.push(
        admin.from("speed_limit_cache").upsert(
          {
            cache_key: segKey,
            speed_limit_mph: mph,
            fetched_at: new Date(now).toISOString(),
            expires_at: expiresAt,
          },
          { onConflict: "cache_key" },
        ),
      );
    }

    await Promise.allSettled(cacheWrites);
  }

  return {
    speed_limit_mph: mph,
    cached: false,
    source: "here",
  };
}

async function handleHereAlert(
  admin: ReturnType<typeof createClient>,
  hereKey: string,
  lat: number,
  lng: number,
  dLat: number | null,
  dLng: number | null,
  headingDeg: number | null,
): Promise<Response> {
  const payload = await resolveHereAlertPayload(
    admin,
    hereKey,
    lat,
    lng,
    dLat,
    dLng,
    headingDeg,
  );
  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    const jwt = authHeader?.replace(/^Bearer\s+/i, "").trim();
    if (!jwt) {
      return new Response(JSON.stringify({ error: "Missing Authorization" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const supabaseService = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const { user, error: authError } = await verifyJwt(
      supabaseUrl,
      supabaseAnon,
      jwt,
    );
    if (authError) return authError;

    const admin = createClient(supabaseUrl, supabaseService);

    const { allowed, error: accessError } = await verifySubscriptionAccess(admin, user.id);
    if (!allowed && accessError) return accessError;

    let body: Body;
    try {
      body = (await req.json()) as Body;
    } catch {
      return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const lat = Number(body.lat);
    const lng = Number(body.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      return new Response(JSON.stringify({ error: "lat/lng required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const kind: "alert" | "route" = body.kind === "route" ? "route" : "alert";

    const dLat =
      body.dest_lat != null && Number.isFinite(Number(body.dest_lat))
        ? Number(body.dest_lat)
        : null;
    const dLng =
      body.dest_lng != null && Number.isFinite(Number(body.dest_lng))
        ? Number(body.dest_lng)
        : null;

    const headingDeg =
      body.heading_degrees != null && Number.isFinite(Number(body.heading_degrees))
        ? Number(body.heading_degrees)
        : null;

    const hereKey = Deno.env.get("HERE_API_KEY");
    if (!hereKey) {
      return new Response(
        JSON.stringify({ error: "Server misconfiguration: HERE_API_KEY" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    if (kind === "route") {
      const origin = `${lat},${lng}`;
      const destination =
        dLat != null && dLng != null
          ? `${dLat},${dLng}`
          : `${lat + 0.00001},${lng + 0.00001}`;
      const json = await fetchHereRoutesJson(hereKey, origin, destination);
      return new Response(JSON.stringify(json), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return await handleHereAlert(admin, hereKey, lat, lng, dLat, dLng, headingDeg);
  } catch (e) {
    console.error(e);
    const msg = e instanceof Error ? e.message : String(e);
    return new Response(JSON.stringify({ error: msg }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
