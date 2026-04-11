import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { corsHeaders, verifyJwt } from "../_shared/auth.ts";

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

    // Ensure profile row exists (for anonymous users who may not have one yet)
    const { data: existingProfile } = await admin
      .from("profiles")
      .select("id, trial_ends_at, subscription_active, subscription_checked_at")
      .eq("id", user.id)
      .maybeSingle();

    const isAnonymous = !user.identities || user.identities.length === 0 ||
      user.identities.every((i: { provider: string }) => i.provider === "anonymous");

    // Auto-create profile row for new anonymous users (3-day trial)
    if (!existingProfile) {
      const trialEnds = new Date(Date.now() + 3 * 24 * 3600_000).toISOString();
      const { data: newProfile } = await admin
        .from("profiles")
        .upsert({
          id: user.id,
          trial_ends_at: trialEnds,
          subscription_active: false,
          subscription_checked_at: new Date().toISOString(),
        }, { onConflict: "id" })
        .select()
        .maybeSingle();

      const trialActive = true; // Just created, trial is active
      if (isAnonymous) {
        // Anonymous user with active trial — no RevenueCat check needed
        return new Response(
          JSON.stringify({
            user_id: user.id,
            access_allowed: true,
            trial_active: true,
            subscription_active: false,
            is_anonymous: true,
          }),
          { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    }

    const profile = existingProfile || (await admin
      .from("profiles")
      .select("trial_ends_at, subscription_active, subscription_checked_at")
      .eq("id", user.id)
      .maybeSingle());

    const trialEndsIso: string | null =
      profile?.trial_ends_at != null ? String(profile.trial_ends_at) : null;
    const trialActive =
      trialEndsIso != null &&
      !Number.isNaN(Date.parse(trialEndsIso)) &&
      Date.parse(trialEndsIso) > Date.now();

    // For anonymous users with active trial, allow access without RevenueCat
    if (isAnonymous && trialActive) {
      await admin
        .from("profiles")
        .update({
          subscription_active: false,
          subscription_checked_at: new Date().toISOString(),
        })
        .eq("id", user.id);

      return new Response(
        JSON.stringify({
          user_id: user.id,
          access_allowed: true,
          trial_active: true,
          subscription_active: false,
          is_anonymous: true,
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // For signed-in users (or anonymous with expired trial), check RevenueCat
    let subscriptionActive = false;

    if (trialActive) {
      subscriptionActive = true;
    } else {
      const rcSecret = Deno.env.get("REVENUECAT_SECRET_API_KEY");
      const entitlementId = Deno.env.get("RC_ENTITLEMENT_ID") ?? "premium";

      if (rcSecret && rcSecret.length > 0) {
        const rcRes = await fetch(
          `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(user.id)}`,
          {
            headers: {
              Authorization: `Bearer ${rcSecret}`,
              "Content-Type": "application/json",
            },
          },
        );
        if (rcRes.ok) {
          const body = (await rcRes.json()) as {
            subscriber?: {
              entitlements?: {
                [k: string]: { expires_date?: string | null; is_active?: boolean };
              };
            };
          };
          const ent = body.subscriber?.entitlements?.[entitlementId];
          console.log(`[AUTH-CHECK] RevenueCat entitlement: key=${entitlementId}, is_active=${ent?.is_active}, expires_date=${ent?.expires_date}`);
          if (ent?.is_active === true) {
            subscriptionActive = true;
          } else if (ent?.expires_date) {
            const t = Date.parse(ent.expires_date);
            console.log(`[AUTH-CHECK] RevenueCat expires_date parsed: ${ent.expires_date} -> timestamp=${t}, now=${Date.now()}, active=${t > Date.now()}`);
            if (!Number.isNaN(t) && t > Date.now()) {
              subscriptionActive = true;
            }
          } else {
            console.log(`[AUTH-CHECK] RevenueCat no entitlement found for ${entitlementId}. Available entitlements: ${JSON.stringify(Object.keys(body.subscriber?.entitlements ?? {}))}`);
          }
        } else {
          console.warn("RevenueCat subscriber fetch failed", rcRes.status, await rcRes.text());
        }
      }
    }

    // Update profiles table with the check result
    await admin
      .from("profiles")
      .update({
        subscription_active: subscriptionActive,
        subscription_checked_at: new Date().toISOString(),
      })
      .eq("id", user.id);

    return new Response(
      JSON.stringify({
        user_id: user.id,
        access_allowed: subscriptionActive,
        trial_active: trialActive,
        subscription_active: subscriptionActive && !trialActive,
        is_anonymous: isAnonymous,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (e) {
    console.error(e);
    const msg = e instanceof Error ? e.message : String(e);
    return new Response(JSON.stringify({ error: msg }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});