// Supabase Edge: HERE (+ cache), TomTom, Mapbox for speed limits. Auth + trial/RevenueCat gate.
// Secrets: HERE_API_KEY; optional TOMTOM_API_KEY, MAPBOX_ACCESS_TOKEN
// Optional: REVENUECAT_SECRET_API_KEY, RC_ENTITLEMENT_ID, CACHE_TTL_HOURS

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const TOMTOM_SNAP_FIELDS =
  "{route{properties{id,speedLimits{value,unit,type}}}}";

type Body = {
  lat: number;
  lng: number;
  dest_lat?: number | null;
  dest_lng?: number | null;
  kind: "alert" | "route" | "compare";
  /** TomTom road matching (degrees clockwise from north). */
  heading_degrees?: number | null;
};

type ProviderSlice = {
  speed_limit_mph: number | null;
  source: string;
  cached?: boolean;
};

const HERE_ALERT_ROUTE_LEAD_METERS = 1000;

function round4(n: number): number {
  return Math.round(n * 1e4) / 1e4;
}

/** Cache key includes exact HERE destination used (nav dest, bearing stub, or north stub). */
function cacheKeyAlert(
  lat: number,
  lng: number,
  destLat: number,
  destLng: number,
): string {
  return `${round4(lat)},${round4(lng)}|${round4(destLat)},${round4(destLng)}`;
}

type HereSpan = {
  offset?: number;
  length?: number;
  speedLimit?: number | null;
};

type HereSection = { spans?: HereSpan[]; polyline?: string | null };

/** First span with speedLimit in API order (origin = vehicle; long lookahead must not pick downstream limit). */
function pickSpeedMpsFromSection(section: HereSection): number | null {
  const spans = section.spans;
  if (!Array.isArray(spans)) return null;
  for (const sp of spans) {
    const sl = sp.speedLimit;
    if (sl != null && typeof sl === "number" && sl > 0) return sl;
  }
  return null;
}

function speedMpsFromHereRoutes(routes: unknown): number | null {
  if (!Array.isArray(routes)) return null;
  for (const route of routes) {
    const sections = (route as { sections?: HereSection[] })?.sections;
    if (!Array.isArray(sections)) continue;
    for (const section of sections) {
      const mps = pickSpeedMpsFromSection(section);
      if (mps != null) return mps;
    }
  }
  return null;
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

/** Offset (lat, lon) by bearing (deg) and distance (m). */
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

/**
 * TomTom returns `detailedError: { code, message }` for billing, auth, and policy errors.
 * Raw `HTTP 403` from Edge is often a **key restriction** (mobile/referrer-locked key used from Supabase IPs).
 */
function tomTomHttpSource(status: number, bodyText: string): string {
  const t = (bodyText ?? "").trim();
  if (t.startsWith("{") || t.startsWith("[")) {
    try {
      const root = JSON.parse(t) as {
        detailedError?: { code?: string; message?: string };
      };
      const d = root.detailedError;
      if (d) {
        const code = (d.code ?? "").toString().trim();
        const msg = (d.message ?? "").toString().trim();
        if (code && msg) {
          return `TomTom: ${code} — ${msg.slice(0, 220)}`;
        }
        if (msg) return `TomTom: HTTP ${status} — ${msg.slice(0, 220)}`;
        if (code) return `TomTom: ${code} (HTTP ${status})`;
      }
    } catch {
      /* ignore */
    }
  }
  if (status === 401) {
    return "TomTom: HTTP 401 — invalid or missing key (check Supabase secret TOMTOM_API_KEY).";
  }
  if (status === 403) {
    return "TomTom: HTTP 403 — if the JSON body is empty, TomTom is usually rejecting **server** calls: keys locked to an Android package or HTTP referrer do not work from Supabase Edge. Use a separate TomTom key with no referrer / mobile-only lock for Edge, or call TomTom only from the app.";
  }
  return `TomTom: HTTP ${status}`;
}

/** True when retrying another TomTom product is unlikely to help (same key). */
function tomTomFailureIsFinal(status: number, source: string): boolean {
  if (status === 401 || status === 403) return true;
  if (status === 402) return true;
  const u = source.toUpperCase();
  return (
    u.includes("INSUFFICIENTFUNDS") ||
    u.includes("INSUFFICIENT FUNDS") ||
    u.includes("FORBIDDEN") ||
    u.includes("UNAUTHORIZED") ||
    u.includes("INVALIDAPIKEY")
  );
}

function parseTomTomSnapSpeedMph(jsonStr: string): number | null {
  try {
    const root = JSON.parse(jsonStr) as {
      detailedError?: unknown;
      route?: unknown[];
    };
    if (root.detailedError) return null;
    const route = root.route;
    if (!Array.isArray(route) || route.length === 0) return null;
    for (const feature of route) {
      const props = (feature as { properties?: Record<string, unknown> })
        ?.properties;
      if (!props) continue;
      const raw = props["speedLimits"];
      const mphFromSl = (sl: { value?: number; unit?: string }): number | null => {
        if (sl.value == null || typeof sl.value !== "number") return null;
        const u = String(sl.unit ?? "kmph").toLowerCase();
        return u.includes("mph") ? Math.round(sl.value) : Math.round(sl.value * 0.621371);
      };
      if (raw && typeof raw === "object" && !Array.isArray(raw)) {
        const m = mphFromSl(raw as { value?: number; unit?: string });
        if (m != null) return m;
      }
      if (Array.isArray(raw)) {
        for (const o of raw) {
          if (o && typeof o === "object") {
            const m = mphFromSl(o as { value?: number; unit?: string });
            if (m != null) return m;
          }
        }
      }
    }
  } catch {
    /* ignore */
  }
  return null;
}

async function fetchTomTomMph(
  key: string,
  lat: number,
  lng: number,
  heading: number | null,
): Promise<ProviderSlice> {
  const bearing = heading != null && Number.isFinite(heading) ? heading : 0;
  const [lat2, lon2] = offsetLatLngMeters(lat, lng, bearing, 95);
  const t0 = new Date();
  t0.setMilliseconds(0);
  const t1 = new Date(t0.getTime() + 2000);
  const iso = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");
  const points = `${lng.toFixed(7)},${lat.toFixed(7)};${lon2.toFixed(7)},${lat2.toFixed(7)}`;
  const headings = `${bearing.toFixed(1)};${bearing.toFixed(1)}`;
  const timestamps = `${iso(t0)};${iso(t1)}`;

  const snapUrl = new URL("https://api.tomtom.com/snapToRoads/1");
  snapUrl.searchParams.set("key", key);
  snapUrl.searchParams.set("points", points);
  snapUrl.searchParams.set("headings", headings);
  snapUrl.searchParams.set("timestamps", timestamps);
  snapUrl.searchParams.set("fields", TOMTOM_SNAP_FIELDS);
  snapUrl.searchParams.set("vehicleType", "PassengerCar");
  snapUrl.searchParams.set("measurementSystem", "auto");

  let snapFailSource: string | null = null;
  let snapFailStatus = 0;

  try {
    const snapRes = await fetch(snapUrl.toString());
    const snapText = await snapRes.text();
    if (snapRes.ok) {
      const mph = parseTomTomSnapSpeedMph(snapText);
      if (mph != null) {
        return { speed_limit_mph: mph, source: "TomTom Snap to Roads API" };
      }
    } else {
      snapFailStatus = snapRes.status;
      snapFailSource = tomTomHttpSource(snapRes.status, snapText);
      if (tomTomFailureIsFinal(snapRes.status, snapFailSource)) {
        return { speed_limit_mph: null, source: snapFailSource };
      }
    }
  } catch (e) {
    console.warn("TomTom snap", e);
  }

  const pos = `${lat.toFixed(7)},${lng.toFixed(7)}`;
  const rg = new URL(
    `https://api.tomtom.com/search/2/reverseGeocode/${pos}.json`,
  );
  rg.searchParams.set("key", key);
  rg.searchParams.set("returnSpeedLimit", "true");
  if (heading != null && Number.isFinite(heading)) {
    rg.searchParams.set("heading", String(Math.round(heading * 10) / 10));
  }
  try {
    const rgRes = await fetch(rg.toString());
    const rgText = await rgRes.text();
    if (!rgRes.ok) {
      const rgSrc = tomTomHttpSource(rgRes.status, rgText);
      if (snapFailSource && snapFailSource !== rgSrc) {
        return {
          speed_limit_mph: null,
          source: `${rgSrc} (snap was HTTP ${snapFailStatus}: ${snapFailSource})`,
        };
      }
      return { speed_limit_mph: null, source: rgSrc };
    }
    const mph = parseTomTomSpeedFromGeocodeJson(rgText);
    if (mph != null) {
      return { speed_limit_mph: mph, source: "TomTom Reverse Geocode API" };
    }
    const tail = snapFailSource
      ? ` Snap had failed: ${snapFailSource}`
      : "";
    return {
      speed_limit_mph: null,
      source: `TomTom (no speed limit data)${tail}`,
    };
  } catch (e) {
    return {
      speed_limit_mph: null,
      source: `TomTom error: ${e instanceof Error ? e.message : String(e)}`,
    };
  }
}

function parseTomTomSpeedFromGeocodeJson(json: string): number | null {
  try {
    const root = JSON.parse(json) as { addresses?: unknown[] };
    const addresses = root.addresses;
    if (!Array.isArray(addresses)) return null;
    const re =
      /([0-9]+(?:\.[0-9]+)?)\s*(MPH|KPH|mph|kph|kmh|KMH|km\/h|mi\/h)?/i;
    for (const item of addresses) {
      const found = findSpeedStringDeep(item as Record<string, unknown>, 0);
      if (!found) continue;
      const m = re.exec(found.trim());
      if (!m) continue;
      const value = parseFloat(m[1]);
      const unit = (m[2] ?? "").toLowerCase();
      if (!Number.isFinite(value)) continue;
      if (unit.includes("mph") || unit.includes("mi/h")) return Math.round(value);
      return Math.round(value * 0.621371);
    }
  } catch {
    /* ignore */
  }
  return null;
}

function findSpeedStringDeep(
  o: Record<string, unknown>,
  depth: number,
): string | null {
  if (depth > 8) return null;
  for (const k of Object.keys(o)) {
    const matches =
      k.toLowerCase() === "speedlimit" ||
      (k.toLowerCase().includes("speed") &&
        k.toLowerCase().includes("limit"));
    const v = o[k];
    if (matches && typeof v === "string" && v.trim()) return v.trim();
    if (typeof v === "object" && v != null && !Array.isArray(v)) {
      const s = findSpeedStringDeep(v as Record<string, unknown>, depth + 1);
      if (s) return s;
    }
    if (Array.isArray(v)) {
      for (const el of v) {
        if (el && typeof el === "object") {
          const s = findSpeedStringDeep(el as Record<string, unknown>, depth + 1);
          if (s) return s;
        }
      }
    }
  }
  return null;
}

function mapboxCoordinatePair(lat: number, lng: number): string {
  const latRad = (lat * Math.PI) / 180;
  const dLat = 0.0011;
  const dLng = 0.0011 / Math.max(0.25, Math.cos(latRad));
  const lat2 = lat + dLat;
  const lng2 = lng + dLng;
  return `${lng.toFixed(6)},${lat.toFixed(6)};${lng2.toFixed(6)},${lat2.toFixed(6)}`;
}

function parseMapboxMaxspeedMph(jsonStr: string): number | null {
  try {
    const root = JSON.parse(jsonStr) as { routes?: unknown[] };
    const routes = root.routes;
    if (!Array.isArray(routes)) return null;
    for (const route of routes) {
      const legs = (route as { legs?: unknown[] }).legs;
      if (!Array.isArray(legs)) continue;
      for (const leg of legs) {
        const ann = (leg as { annotation?: { maxspeed?: unknown[] } }).annotation;
        const arr = ann?.maxspeed;
        const mph = parseMaxspeedArray(arr);
        if (mph != null) return mph;
      }
    }
  } catch {
    /* ignore */
  }
  return null;
}

function parseMaxspeedArray(arr: unknown): number | null {
  if (!Array.isArray(arr)) return null;
  for (const item of arr) {
    if (item == null || typeof item !== "object") continue;
    const o = item as { speed?: number; unit?: string };
    if (o.speed == null || typeof o.speed !== "number") continue;
    const unit = String(o.unit ?? "").toLowerCase();
    if (unit.includes("mph")) return Math.round(o.speed);
    return Math.round(o.speed * 0.621371);
  }
  return null;
}

async function fetchMapboxMph(
  token: string,
  lat: number,
  lng: number,
): Promise<ProviderSlice> {
  const coords = mapboxCoordinatePair(lat, lng);
  const q = new URLSearchParams({
    access_token: token,
    annotations: "maxspeed",
    geometries: "geojson",
    overview: "full",
  });
  const url =
    `https://api.mapbox.com/directions/v5/mapbox/driving/${
      encodeURIComponent(coords)
    }?${q.toString()}`;
  try {
    const res = await fetch(url);
    const text = await res.text();
    if (!res.ok) {
      return {
        speed_limit_mph: null,
        source: `Mapbox: HTTP ${res.status}`,
      };
    }
    const mph = parseMapboxMaxspeedMph(text);
    if (mph != null) {
      return { speed_limit_mph: mph, source: "Mapbox Directions API" };
    }
    return {
      speed_limit_mph: null,
      source: "Mapbox Directions API (no maxspeed annotation)",
    };
  } catch (e) {
    return {
      speed_limit_mph: null,
      source: `Mapbox error: ${e instanceof Error ? e.message : String(e)}`,
    };
  }
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
  let destLat: number;
  let destLng: number;
  if (
    dLat != null && dLng != null && Number.isFinite(dLat) && Number.isFinite(dLng)
  ) {
    destLat = dLat;
    destLng = dLng;
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

  const key = cacheKeyAlert(lat, lng, destLat, destLng);
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

  const hereJson = (await fetchHereRoutesJson(
    hereKey,
    origin,
    destination,
  )) as { routes?: unknown };
  const mps = speedMpsFromHereRoutes(hereJson.routes);
  const mph = mps != null ? Math.round(mps * 2.23694) : null;

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

    const kind: "alert" | "route" | "compare" =
      body.kind === "route"
        ? "route"
        : body.kind === "compare"
        ? "compare"
        : "alert";

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
    const tomtomKey = Deno.env.get("TOMTOM_API_KEY");
    const mapboxToken = Deno.env.get("MAPBOX_ACCESS_TOKEN");

    if (kind === "route") {
      if (!hereKey) {
        return new Response(
          JSON.stringify({ error: "Server misconfiguration: HERE_API_KEY" }),
          {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          },
        );
      }
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

    if (kind === "compare") {
      if (!hereKey && !tomtomKey && !mapboxToken) {
        return new Response(
          JSON.stringify({
            error: "Server misconfiguration: set HERE_API_KEY and/or TOMTOM_API_KEY and/or MAPBOX_ACCESS_TOKEN",
          }),
          {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          },
        );
      }

      const hereSlice: ProviderSlice = !hereKey
        ? {
          speed_limit_mph: null,
          source: "HERE not configured on server",
        }
        : await (async (): Promise<ProviderSlice> => {
          const j = await resolveHereAlertPayload(
            admin,
            hereKey,
            lat,
            lng,
            null,
            null,
            headingDeg,
          );
          return {
            speed_limit_mph: j.speed_limit_mph,
            source: j.source,
            cached: j.cached,
          };
        })();

      const [tomtomSlice, mapboxSlice] = await Promise.all([
        !tomtomKey
          ? Promise.resolve({
            speed_limit_mph: null,
            source: "TomTom not configured on server",
          } as ProviderSlice)
          : fetchTomTomMph(tomtomKey, lat, lng, headingDeg),
        !mapboxToken
          ? Promise.resolve({
            speed_limit_mph: null,
            source: "Mapbox not configured on server",
          } as ProviderSlice)
          : fetchMapboxMph(mapboxToken, lat, lng),
      ]);

      return new Response(
        JSON.stringify({
          providers: {
            here: hereSlice,
            tomtom: tomtomSlice,
            mapbox: mapboxSlice,
          },
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // kind === "alert"
    if (!hereKey) {
      return new Response(
        JSON.stringify({ error: "Server misconfiguration: HERE_API_KEY" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
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
