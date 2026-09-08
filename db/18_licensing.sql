-- ============================================================
-- JYOTHI FOODS ERP — 18: LICENSING (T11.2)
-- A licence key is issued per organisation by the vendor and
-- activated from the app. Only a hash of the key is stored
-- (orgs.license_key), so reading the orgs row reveals nothing.
--
-- States, from license_status():
--   trial       no key yet, within trial_days of the org's creation
--   unlicensed  no key and the trial is over               → read-only
--   active      key present, today <= license_valid_till
--   grace       key lapsed within license_grace_days      (warnings only)
--   expired     key lapsed beyond the grace days           → read-only
--
-- Read-only means: viewing and exporting still work, creating documents
-- is blocked by enforce_license() on the document header tables. The
-- service role (backups, scheduled jobs) is never blocked.
-- ============================================================

alter table orgs
  add column if not exists trial_days integer not null default 30,
  add column if not exists license_grace_days integer not null default 7,
  add column if not exists license_max_devices integer not null default 3,
  add column if not exists licensed_to text;

create table if not exists license_devices (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  device_id     text not null,
  device_name   text,
  platform      text,
  app_version   text,
  activated_by  uuid references staff(id),
  activated_at  timestamptz not null default now(),
  last_seen     timestamptz not null default now(),
  unique (org_id, device_id)
);
alter table license_devices enable row level security;
drop policy if exists org_read on license_devices;
create policy org_read on license_devices for select using (org_id = my_org_id());

create or replace view v_license_devices as
select d.*, st.full_name as activated_by_name
  from license_devices d left join staff st on st.id = d.activated_by;
alter view v_license_devices set (security_invoker = on);

create or replace function license_hash(p_key text) returns text
language sql immutable as $$
  select encode(sha256(convert_to(upper(regexp_replace(coalesce(p_key, ''), '[^A-Za-z0-9]', '', 'g')), 'UTF8')), 'hex');
$$;

/** The licence state of one org as a row of facts. */
create or replace function license_state(p_org uuid)
returns table (status text, valid_till date, days_left integer, read_only boolean, grace_days integer, trial_days integer)
language plpgsql stable security definer set search_path = public as $$
declare o orgs%rowtype; trial_end date;
begin
  select * into o from orgs where id = p_org;
  if not found then return; end if;
  if o.license_valid_till is null then
    trial_end := o.created_at::date + o.trial_days;
    if current_date <= trial_end then
      return query select 'trial', trial_end, (trial_end - current_date), false, o.license_grace_days, o.trial_days;
    else
      return query select 'unlicensed', trial_end, (trial_end - current_date), true, o.license_grace_days, o.trial_days;
    end if;
  elsif current_date <= o.license_valid_till then
    return query select 'active', o.license_valid_till, (o.license_valid_till - current_date), false, o.license_grace_days, o.trial_days;
  elsif current_date <= o.license_valid_till + o.license_grace_days then
    return query select 'grace', o.license_valid_till, (o.license_valid_till - current_date), false, o.license_grace_days, o.trial_days;
  else
    return query select 'expired', o.license_valid_till, (o.license_valid_till - current_date), true, o.license_grace_days, o.trial_days;
  end if;
end $$;

create or replace function license_blocked(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select s.read_only from license_state(p_org) s), false);
$$;

/**
 * What the app asks on start-up and every half hour. When a device id is given the
 * device's last_seen is stamped (a known device only; activation registers new ones).
 */
create or replace function license_status(p_device_id text default null, p_app_version text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s record; o orgs%rowtype; n int; known boolean := false;
begin
  if v_org is null then raise exception 'Not a member of any organisation'; end if;
  select * into o from orgs where id = v_org;
  select * into s from license_state(v_org);
  if p_device_id is not null then
    update license_devices set last_seen = now(), app_version = coalesce(p_app_version, app_version)
     where org_id = v_org and device_id = p_device_id;
    known := found;
  end if;
  select count(*) into n from license_devices where org_id = v_org;
  return jsonb_build_object('status', s.status, 'valid_till', s.valid_till, 'days_left', s.days_left, 'read_only', s.read_only,
                            'grace_days', s.grace_days, 'trial_days', s.trial_days, 'licensed_to', o.licensed_to,
                            'has_key', o.license_key is not null, 'devices', n, 'max_devices', o.license_max_devices,
                            'this_device_known', known, 'checked_at', now());
end $$;

/** Owner or admin types the key on a device. The key must match; the device is registered. */
create or replace function activate_license(p_key text, p_device_id text, p_device_name text default null, p_platform text default null, p_app_version text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); o orgs%rowtype; n int;
begin
  if my_role() not in ('owner', 'admin') then raise exception 'Only the owner or an admin can activate the licence'; end if;
  select * into o from orgs where id = v_org;
  if o.license_key is null then raise exception 'No licence has been issued for this organisation yet'; end if;
  if license_hash(p_key) <> o.license_key then raise exception 'Licence key not recognised'; end if;
  if p_device_id is null or p_device_id = '' then raise exception 'Device id is required'; end if;
  if not exists (select 1 from license_devices where org_id = v_org and device_id = p_device_id) then
    select count(*) into n from license_devices where org_id = v_org;
    if n >= o.license_max_devices then
      raise exception 'Device limit reached (%). Remove a device under Setup → Licence first.', o.license_max_devices;
    end if;
  end if;
  insert into license_devices (org_id, device_id, device_name, platform, app_version, activated_by)
  values (v_org, p_device_id, p_device_name, p_platform, p_app_version, my_staff_id())
  on conflict (org_id, device_id) do update set device_name = coalesce(excluded.device_name, license_devices.device_name),
    platform = coalesce(excluded.platform, license_devices.platform), app_version = coalesce(excluded.app_version, license_devices.app_version),
    last_seen = now();
  return license_status(p_device_id, p_app_version);
end $$;

create or replace function remove_license_device(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role() <> 'owner' then raise exception 'Only the owner can remove a device'; end if;
  delete from license_devices where id = p_id and org_id = my_org_id();
end $$;

-- ------------------------------------------------------------
-- Vendor side (service role only, i.e. the SQL editor as postgres):
--   select issue_license('<org id>', '2027-09-30', 'Jyothi Foods, Guntur');
-- prints the key ONCE; only its hash is kept. renew_license() moves the date.
-- ------------------------------------------------------------
create or replace function issue_license(p_org uuid, p_valid_till date, p_licensed_to text default null, p_max_devices integer default null) returns text
language plpgsql security definer set search_path = public as $$
declare v_key text; raw text;
begin
  if not is_service_call() then raise exception 'Licences are issued by the vendor only'; end if;
  raw := upper(encode(gen_random_bytes(10), 'hex'));   -- 20 hex chars
  v_key := 'JF-' || substr(raw, 1, 5) || '-' || substr(raw, 6, 5) || '-' || substr(raw, 11, 5) || '-' || substr(raw, 16, 5);
  update orgs set license_key = license_hash(v_key), license_valid_till = p_valid_till,
                  licensed_to = coalesce(p_licensed_to, licensed_to), license_max_devices = coalesce(p_max_devices, license_max_devices)
   where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
  return v_key;
end $$;

create or replace function renew_license(p_org uuid, p_valid_till date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_service_call() then raise exception 'Licences are renewed by the vendor only'; end if;
  update orgs set license_valid_till = p_valid_till where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
end $$;

revoke execute on function issue_license(uuid, date, text, integer) from public, anon, authenticated;
revoke execute on function renew_license(uuid, date) from public, anon, authenticated;

-- ------------------------------------------------------------
-- Enforcement: no new documents once the licence has lapsed.
-- ------------------------------------------------------------
create or replace function enforce_license() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_service_call() then return new; end if;
  if license_blocked(new.org_id) then
    raise exception 'The licence has lapsed — the app is read-only. Renew it under Setup → Licence to create documents.'
      using errcode = 'P0001', hint = 'license_lapsed';
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'invoices', 'receipts', 'payments', 'purchases', 'sales_returns', 'purchase_returns', 'quotations', 'orders', 'delivery_challans',
    'production_batches', 'stock_transfers', 'stock_counts', 'account_transfers', 'vehicle_trips', 'stock_ledger'
  ] loop
    execute format('drop trigger if exists t_license on %I', t);
    execute format('create trigger t_license before insert on %I for each row execute function enforce_license()', t);
  end loop;
end $$;
