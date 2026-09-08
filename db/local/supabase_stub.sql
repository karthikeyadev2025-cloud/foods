-- ============================================================
-- A local Postgres that behaves like Supabase.
--
-- Run this into an empty database before db/apply.sh. It exists because a
-- plain Postgres is more forgiving than Supabase in two ways that have both
-- already cost us a live bug:
--
--   1. auth.uid(). Every policy and every is_service_call() reads it. Supabase
--      provides it; a plain Postgres does not.
--
--   2. WHERE THE EXTENSIONS LIVE. Supabase installs pgcrypto and pg_trgm into
--      a schema called `extensions`, not into public. A plain
--      `create extension pgcrypto` puts them in public, where every function
--      can see them — including functions that pin `set search_path = public`.
--      On Supabase those same functions cannot, and fail at run time with
--      "function gen_random_bytes(integer) does not exist" — which is exactly
--      how issue_license() shipped broken while passing every local test.
--
-- So this installs them the Supabase way and leaves public clean. If a
-- migration ever reaches for an extension function from inside a
-- search_path-pinned function again, it now fails here first.
--
--   psql "$DATABASE_URL" -f db/local/supabase_stub.sql
--   DATABASE_URL=... bash db/apply.sh
-- ============================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- Supabase grants every client role usage on this schema, so a function that names
-- `extensions` in its search_path can actually reach it. Without the grant the schema
-- is on the path but invisible, and the failure reads identically to a missing
-- function — worth knowing, because that is a confusing hour otherwise.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
end $$;
grant usage on schema extensions to public;

-- Supabase's SQL Editor session can see the extensions schema, which is why DDL
-- like `using gin (name gin_trgm_ops)` resolves at apply time. Functions that pin
-- their own search_path still cannot — that asymmetry is the whole point.
do $$
begin
  execute format('alter database %I set search_path = public, extensions', current_database());
end $$;

create schema if not exists auth;

/** Supabase's auth.uid(): the signed-in user, or null for the service role. */
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
