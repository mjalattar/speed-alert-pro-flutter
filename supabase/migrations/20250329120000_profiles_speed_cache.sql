-- Speed Alert Pro: profile (trial) + server-side speed limit cache for HERE proxy.
-- Run via Supabase SQL editor or: supabase db push

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  trial_ends_at timestamptz not null,
  created_at timestamptz not null default (now() at time zone 'utc')
);

alter table public.profiles enable row level security;

create policy "Users can read own profile"
  on public.profiles
  for select
  to authenticated
  using (auth.uid() = id);

-- Cache rows are read/written only by Edge Functions (service role), not from the mobile client.
create table if not exists public.speed_limit_cache (
  cache_key text primary key,
  speed_limit_mph int not null,
  fetched_at timestamptz not null default (now() at time zone 'utc'),
  expires_at timestamptz not null
);

create index if not exists speed_limit_cache_expires_at_idx
  on public.speed_limit_cache (expires_at);

alter table public.speed_limit_cache enable row level security;

-- No client policies on cache; service role bypasses RLS.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, trial_ends_at)
  values (
    new.id,
    (now() at time zone 'utc') + interval '3 days'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();
