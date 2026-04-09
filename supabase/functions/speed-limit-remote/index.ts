// Supabase Edge `speed-limit-remote`: HERE Routes v8 + optional `speed_limit_cache` (auth + trial/RevenueCat gate).
// Secrets: HERE_API_KEY; optional REVENUECAT_SECRET_API_KEY, RC_ENTITLEMENT_ID, CACHE_TTL_HOURS

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { parseAlertMphFromHereRoutesJson } from "./speed_limit_remote.ts";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

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
const HERE_ALERT_CACHE_RULE = "2026-04-floor-h30";

/** Origin coordinates floored to this many decimal places for cache keys. */
const ORIGIN_DECIMALS = 3; // ~111 m cell

/** Heading bucket width (degrees). 360 / 30 = 12 compass points. */
const HEADING_BUCKET_DEGREES = 30;

function cacheFloor(n: number, decimals: number): number {
  const f = 10 ** decimals;
  return Math.floor(n * f) / f;
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
  const h = headingDeg != null && Number.isFinite(headingDeg)
    ? Math.floor((((headingDeg % 360) + 360) % 360) / HEADING_BUCKET_DEGREES) * HEADING_BUCKET_DEGREES
    : 0;
  return `${origin}|h${h}|${HERE_ALERT_CACHE_RULE}`;
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

async function userMayAccessSpeedApi(
  userId: string,
  trialEndsAtIso: string | null,
  rcSecret: string | undefined,
  entitlementId: string,
): Promise<boolean> {
  const trialOk =
    trialEndsAtIso != null &&
    !Number.isNaN(Date.parse(trialEndsAtIso)) &&
    Date.parse(trialEndsAtIso) > Date.now();
  if (trialOk) return true;

  if (!rcSecret || rcSecret.length === 0) {
    return false;
  }

  const rcRes = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userId)}`,
    {
      headers: {
        Authorization: `Bearer ${rcSecret}`,
        "Content-Type": "application/json",
      },
    },
  );
  if (!rcRes.ok) {
    console.warn("RevenueCat subscriber fetch failed", rcRes.status);
    return false;
  }
  const body = (await rcRes.json()) as {
    subscriber?: {
      entitlements?: {
        [k: string]: { expires_date?: string | null; is_active?: boolean };
      };
    };
  };
  const ent = body.subscriber?.entitlements?.[entitlementId];
  if (!ent) return false;
  if (ent.is_active === true) return true;
  if (ent.expires_date) {
    const t = Date.parse(ent.expires_date);
    return !Number.isNaN(t) && t > Date.now();
  }
  return false;
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

  const key = cacheKeyAlert(lat, lng, headingDeg, hasExplicitDest, destLat, destLng);
  const ttlHours = Number(Deno.env.get("CACHE_TTL_HOURS") ?? "24") || 24;
  const now = Date.now();

  const { data: cached, error: cacheReadErr } = await admin
    .from("speed_limit_cache")
    .select("speed_limit_mph, expires_at")
    .eq("cache_key", key)
    .maybeSingle();

  if (!cacheReadErr && cached?.expires_at) {
    const exp = Date.parse(String(cached.expires_at));
    if (!Number.isNaN(exp) && exp > now && cached.speed_limit_mph != null) {
      return {
        speed_limit_mph: cached.speed_limit_mph,
        cached: true,
        source: "cache",
      };
    }
  }

  const hereJson = await fetchHereRoutesJson(
    hereKey,
    origin,
    destination,
  );
  const mph = parseAlertMphFromHereRoutesJson(
    hereJson,
    lat,
    lng,
    headingDeg,
  );

  if (mph != null) {
    const expiresAt = new Date(now + ttlHours * 3600_000).toISOString();
    await admin.from("speed_limit_cache").upsert(
      {
        cache_key: key,
        speed_limit_mph: mph,
        fetched_at: new Date(now).toISOString(),
        expires_at: expiresAt,
      },
      { onConflict: "cache_key" },
    );
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

    const userClient = createClient(supabaseUrl, supabaseAnon, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });
    const {
      data: { user },
      error: userErr,
    } = await userClient.auth.getUser(jwt);
    if (userErr || !user) {
      return new Response(
        JSON.stringify({ error: "Invalid or expired session" }),
        {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const admin = createClient(supabaseUrl, supabaseService);

    const { data: profile, error: profErr } = await admin
      .from("profiles")
      .select("trial_ends_at")
      .eq("id", user.id)
      .maybeSingle();

    if (profErr) {
      console.error("profiles read", profErr);
    }

    const trialEnds =
      profile?.trial_ends_at != null
        ? String(profile.trial_ends_at)
        : null;

    const rcSecret = Deno.env.get("REVENUECAT_SECRET_API_KEY");
    const entitlementId = Deno.env.get("RC_ENTITLEMENT_ID") ?? "premium";

    const allowed = await userMayAccessSpeedApi(
      user.id,
      trialEnds,
      rcSecret ?? undefined,
      entitlementId,
    );

    if (!allowed) {
      return new Response(
        JSON.stringify({
          error: "subscription_required",
          message:
            "Free trial ended or no active subscription. Please subscribe in the app.",
        }),
        {
          status: 402,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

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
