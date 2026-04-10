-- Speed Alert Pro: purge stale cache rows (old fine-grained keys).

-- 1) Delete all rows keyed under old cache rules that will never be looked up again.
DELETE FROM public.speed_limit_cache
WHERE cache_key LIKE '%|2026-04-dart-parity';

DELETE FROM public.speed_limit_cache
WHERE cache_key LIKE '%|2026-04-alert-coarse-hdg';

DELETE FROM public.speed_limit_cache
WHERE cache_key LIKE '%|2026-04-floor-h30';

-- 2) Delete any rows that have already expired (belt-and-suspenders).
DELETE FROM public.speed_limit_cache
WHERE expires_at < now();