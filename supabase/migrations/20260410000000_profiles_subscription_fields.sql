-- Speed Alert Pro: add subscription access fields to profiles.
-- The auth-check edge function writes these; speed-limit-remote reads them
-- instead of calling RevenueCat directly, achieving clean separation.

alter table public.profiles
  add column if not exists subscription_active boolean not null default false,
  add column if not exists subscription_checked_at timestamptz;

-- Speed-limit-remote will check: subscription_active AND checked within 24h.
-- Stale entries force the app to call auth-check again before speed-limit requests.