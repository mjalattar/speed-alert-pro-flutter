-- Speed Alert Pro: enable anonymous sign-in access.
-- 1. Allow anonymous users to read their own profile (needed for trial check in-app).
-- 2. Add RLS policy for anon role on profiles.
-- NOTE: You must also enable anonymous sign-ins in the Supabase Dashboard:
--   Authentication → Providers → Email → turn ON "Allow anonymous sign-ins"

-- Allow anon users to read their own profile row
create policy "Anonymous users can read own profile"
  on public.profiles
  for select
  to anon
  using (auth.uid() = id);