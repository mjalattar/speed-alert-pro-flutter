-- Speed Alert Pro: enable anonymous sign-ins for first-launch experience.
-- Anonymous users get a 3-day trial; the auth-check function auto-creates
-- their profile row with trial_ends_at = now + 3 days.

-- enable anonymous sign-ins
update auth.config
set value = true
where key = 'enable_anonymous_sign_ins';

-- If the row doesn't exist yet (new project), insert it:
insert into auth.config (key, value)
values ('enable_anonymous_sign_ins', true)
on conflict (key) do nothing;