-- ============================================================
-- JYOTHI FOODS ERP — 23: THE EXTENSION FIX, FOR DATABASES ALREADY BUILT
--
-- 13, 18 and 21 have been corrected in place, so a fresh install needs
-- nothing from this file. It exists for a database that is already running,
-- where re-running 13 is NOT the way to pick the fix up: 20_voice.sql widens
-- v_message_log, and `create or replace view` cannot narrow a view again —
-- "cannot drop columns from view". Migrations only ever go forward.
--
-- So this restates just the three functions that were wrong, and nothing else.
-- Safe to run on any database that has reached 21. Safe to run twice.
--
-- What was wrong: gen_random_bytes() belongs to pgcrypto, and Supabase keeps
-- pgcrypto in a schema called `extensions` rather than in public. Functions
-- that pin `search_path = public` therefore cannot see it, and issue_license()
-- failed with "function gen_random_bytes(integer) does not exist" — no licence
-- key could be issued at all. The random values now come from core Postgres
-- instead. similarity() is the same story from pg_trgm, but an extension
-- operator has no core equivalent, so that one names the schema explicitly.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The webhook secret's default, for a table that already exists
-- ------------------------------------------------------------
alter table messaging_settings alter column webhook_secret
  set default substr(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 1, 48);

-- ------------------------------------------------------------
-- 2. Rotating that secret by hand
-- ------------------------------------------------------------
create or replace function rotate_webhook_secret() returns text
language plpgsql security definer set search_path = public as $$
-- gen_random_bytes() is pgcrypto. Supabase installs pgcrypto into the extensions
-- schema, and this function pins search_path to public, so the call resolves on a
-- plain Postgres and fails on Supabase with "function does not exist".
-- gen_random_uuid() is core Postgres and needs no extension at all.
declare v_secret text := substr(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 1, 48);
begin
  if not can_edit('messaging') then raise exception 'Only a role with Messaging edit rights can rotate the secret'; end if;
  update messaging_settings set webhook_secret = v_secret, updated_at = now() where org_id = my_org_id();
  return v_secret;
end $$;

-- ------------------------------------------------------------
-- 3. Matching a WhatsApp order's item names, which needs pg_trgm
-- ------------------------------------------------------------
/**
 * Matching what the customer said to real items. The fuzzy name match uses
 * similarity(), which belongs to pg_trgm — and Supabase keeps its extensions in a
 * schema called `extensions`, not in public. So the search_path is pinned to both:
 * a schema that does not exist is ignored, which makes this work on Supabase and on
 * a plain Postgres alike. Without it the match works from the SQL Editor, whose
 * session happens to see `extensions`, and fails from the app, whose role may not.
 */
create or replace function inbound_order_lines(p_order uuid)
returns table (idx integer, raw_code text, raw_name text, qty numeric, uom text, confidence numeric,
               item_id uuid, item_code text, item_name text, units_per_box integer, base_uom text,
               boxes numeric, rate numeric, match text, low_confidence boolean)
language sql stable set search_path = public, extensions as $$
  with o as (select * from inbound_orders where id = p_order),
  raw as (
    select x.ord::int as idx, x.e->>'item_code' as raw_code, coalesce(x.e->>'item_name', x.e->>'name') as raw_name,
           nullif(x.e->>'qty', '')::numeric as qty, x.e->>'uom' as uom, nullif(x.e->>'confidence', '')::numeric as confidence
      from o, jsonb_array_elements(coalesce(o.parsed_items, '[]'::jsonb)) with ordinality as x(e, ord)),
  m as (
    select raw.*,
           (select i.id from items i, o where i.org_id = o.org_id and i.is_active and raw.raw_code is not null
              and normalize_item_code(i.item_code) = normalize_item_code(raw.raw_code) limit 1) as by_code,
           (select i.id from items i, o where i.org_id = o.org_id and i.is_active and raw.raw_name is not null
              and similarity(i.name, raw.raw_name) >= 0.3
             order by similarity(i.name, raw.raw_name) desc limit 1) as by_name
      from raw)
  select m.idx, m.raw_code, m.raw_name, m.qty, m.uom, m.confidence,
         i.id, i.item_code, i.name, i.units_per_box, u.code,
         case when i.id is null then m.qty
              when m.uom is null or lower(m.uom) in ('box', 'boxes', 'bx', 'పెట్టె', 'పెట్టెలు') then m.qty
              when upper(m.uom) = upper(u.code) or lower(m.uom) in ('unit', 'units', 'jar', 'jars', 'pack', 'packs', 'pkt', 'pkts')
                then round(m.qty / nullif(i.units_per_box, 0), 3)
              else m.qty end,
         case when i.id is null then null
              when o.customer_id is null then i.unit_rate
              else effective_unit_rate(i.id, o.customer_id, current_date) end,
         case when m.by_code is not null then 'code' when m.by_name is not null then 'name' else 'none' end,
         m.by_code is null or coalesce(m.confidence, 1) < 0.7
    from m
    cross join o
    left join items i on i.id = coalesce(m.by_code, m.by_name)
    left join uoms u on u.id = i.base_uom_id
   order by m.idx;
$$;

-- ------------------------------------------------------------
-- 4. Issuing a licence key — the one that was completely broken
-- ------------------------------------------------------------
create or replace function issue_license(p_org uuid, p_valid_till date, p_licensed_to text default null, p_max_devices integer default null, p_plan text default 'full') returns text
language plpgsql security definer set search_path = public as $$
declare v_key text; raw text;
begin
  if not is_service_call() then raise exception 'Licences are issued by the vendor only'; end if;
  if p_plan not in ('starter', 'growth', 'full') then raise exception 'Plan must be starter, growth or full'; end if;
  -- 20 hex characters of randomness. gen_random_uuid() is core Postgres and is
  -- always visible; gen_random_bytes() is pgcrypto, which Supabase installs into
  -- the extensions schema, and this function pins search_path to public — so the
  -- pgcrypto call resolved on a plain Postgres and failed on the real one.
  raw := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 20));
  v_key := 'JF-' || substr(raw, 1, 5) || '-' || substr(raw, 6, 5) || '-' || substr(raw, 11, 5) || '-' || substr(raw, 16, 5);
  update orgs set license_key = license_hash(v_key), license_valid_till = p_valid_till,
                  licensed_to = coalesce(p_licensed_to, licensed_to), license_max_devices = coalesce(p_max_devices, license_max_devices),
                  license_plan = p_plan
   where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
  return v_key;
end $$;

-- A quick proof it works, without changing anything:
--   select substr(replace(gen_random_uuid()::text, '-', ''), 1, 20);
-- If that returns 20 characters, issue_license() will now run.
