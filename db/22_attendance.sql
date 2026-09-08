-- ============================================================
-- JYOTHI FOODS ERP — 22: STAFF ATTENDANCE, AND PUNCHLY
--
-- The attendance table has existed since 01_schema.sql and was never
-- filled. This file fills it two ways: by hand, and from Punchly
-- (https://punchly.online/api/v1), the phone app the staff punch on.
--
-- Punchly gives punches — a check_in and a check_out event, each with
-- its own timestamp. This ERP wants one row per person per day. The
-- folding happens here, in upsert_punchly_attendance(), so the edge
-- function stays a thin fetch-and-hand-over.
--
-- Two rules that matter:
--   • a row a person edited by hand is never overwritten by a later
--     sync (attendance.source says who wrote it)
--   • punches arrive late — a phone out of signal delivers at 19:00
--     something that happened at 08:42 — so the sync always re-reads
--     yesterday as well as today, and upserts rather than inserts
-- ============================================================

-- ------------------------------------------------------------
-- 1. Who is who, and what a day looked like
-- ------------------------------------------------------------
alter table staff
  add column if not exists punchly_user_id text,
  add column if not exists punchly_staff_id text,
  add column if not exists designation text;
create unique index if not exists staff_punchly_idx on staff(org_id, punchly_user_id) where punchly_user_id is not null;

alter table attendance
  add column if not exists source text not null default 'manual' check (source in ('manual', 'punchly')),
  add column if not exists first_in_at timestamptz,
  add column if not exists last_out_at timestamptz,
  add column if not exists worked_hours numeric(6,2),
  add column if not exists punches integer not null default 0,
  add column if not exists branch_name text,
  add column if not exists shift_name text,
  add column if not exists needs_review boolean not null default false,
  add column if not exists notes text,
  add column if not exists updated_at timestamptz not null default now();
create index if not exists attendance_org_date_idx on attendance(org_id, work_date);

/** Staff wages are a payments matter, not a setup one — an accountant runs them. */
do $$
begin
  execute 'drop policy if exists org_read on attendance';
  execute 'drop policy if exists mod_insert on attendance';
  execute 'drop policy if exists mod_update on attendance';
  execute 'drop policy if exists mod_delete on attendance';
  execute 'create policy org_read on attendance for select using (org_id = my_org_id() and can_view(''payments''))';
  execute 'create policy mod_insert on attendance for insert with check (org_id = my_org_id() and can_edit(''payments''))';
  execute 'create policy mod_update on attendance for update using (org_id = my_org_id() and can_edit(''payments'')) with check (org_id = my_org_id() and can_edit(''payments''))';
  execute 'create policy mod_delete on attendance for delete using (org_id = my_org_id() and can_delete(''payments''))';
end $$;

/**
 * Punchly's key is a server-side secret, exactly like Hey Nikki's: this table gets no
 * policy for signed-in users at all, so the browser cannot read it however it asks. The
 * screen goes through get_punchly_settings(), which hands back the last four characters
 * and nothing else; only the edge function, on the service role, sees the whole key.
 */
create table if not exists punchly_settings (
  org_id          uuid primary key references orgs(id) on delete cascade,
  is_enabled      boolean not null default false,
  api_url         text not null default 'https://punchly.online/api/v1',
  api_key         text,
  /** A working day at or above this many hours is present; below it, half a day. */
  full_day_hours  numeric(5,2) not null default 8 check (full_day_hours > 0),
  /** Shorter than this and somebody should look at the row. */
  half_day_hours  numeric(5,2) not null default 4 check (half_day_hours > 0),
  /** Fill wage_amount from staff.daily_wage as the rows come in. */
  auto_wage       boolean not null default true,
  /** Their GPS is personal data under the DPDP Act; off unless the client asks. */
  store_location  boolean not null default false,
  backfill_from   date,
  last_sync_at    timestamptz,
  last_sync_note  text,
  updated_at      timestamptz not null default now()
);
alter table punchly_settings
  /** Punchly asks for one wider pull a week, to catch what an admin corrected after the fact. */
  add column if not exists reconcile_days integer not null default 14 check (reconcile_days between 2 and 366),
  add column if not exists last_reconcile_at timestamptz;
alter table punchly_settings enable row level security;
drop policy if exists org_scope on punchly_settings;

alter table attendance add column if not exists latitude numeric(9,6);
alter table attendance add column if not exists longitude numeric(9,6);

-- ------------------------------------------------------------
-- 2. Attendance is part of running the operation → Growth.
-- ------------------------------------------------------------
create or replace function plan_features(p_plan text) returns text[]
language sql immutable as $$
  select case p_plan
    when 'starter' then array['core']
    when 'growth'  then array['core', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents', 'attendance']
    else array['core', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents', 'attendance',
               'messaging', 'inventory', 'owner', 'insights', 'mobile', 'desktop']
  end;
$$;

create or replace function feature_catalogue()
returns table (feature text, label text, plan text, detail text)
language sql immutable as $$
  select * from (values
    ('core',       'Billing & collection', 'starter', 'Items, customers, invoices and prints, receipts, stock on hand, the day''s reports, setup and users'),
    ('purchases',  'Purchases',            'growth',  'Supplier bills, suppliers, purchase returns'),
    ('returns',    'Sales returns',        'growth',  'Fresh return, rate difference and damage return'),
    ('payments',   'Payments & accounts',  'growth',  'Payments, expenses, cash and bank books, cheques, journal, trial balance, P&L, balance sheet'),
    ('production', 'Production',           'growth',  'Recipes, batches, chief actuals, variance'),
    ('vehicles',   'Vans & trips',         'growth',  'Trips, van loading, loading sheet, settlement'),
    ('documents',  'Quotations & pricing', 'growth',  'Quotations, sale and purchase orders, delivery challans, price lists, discount schemes'),
    ('attendance', 'Attendance & wages',   'growth',  'The daily register, hours and wages per staff, and the Punchly phone-punch sync'),
    ('messaging',  'WhatsApp & calls',     'full',    'Templates, payment reminders, new-stock and catalog broadcasts, inbound orders, reminder and order-taking calls'),
    ('inventory',  'Batches & barcodes',   'full',    'Batch and expiry tracking, barcode labels, godown transfers, physical stock counts'),
    ('owner',      'Owner control',        'full',    'Print designer, backup and restore, audit trail'),
    ('insights',   'Profit & incentives',  'full',    'Route profitability and salesman incentive statements'),
    ('mobile',     'Driver''s phone',      'full',    'Van sales, on-the-spot receipts and delivery proof from a phone'),
    ('desktop',    'Desktop & offline',    'full',    'The installed Windows app, and working without a connection')
  ) as t(feature, label, plan, detail);
$$;

/**
 * Attendance rides on the Payments module, which opens at Growth, so a Starter client
 * cannot see the register at all — the rows keep sitting there, and Growth hands every
 * one of them back. The restrictive policy is what would stop the writes if attendance
 * were ever moved to a plan above the module it lives in; the module gate is doing the
 * work today. punchly_settings needs no policy: nobody signed in can reach it either way.
 */
do $$
begin
  execute 'drop policy if exists plan_insert on attendance';
  execute 'drop policy if exists plan_update on attendance';
  execute 'drop policy if exists plan_delete on attendance';
  execute 'create policy plan_insert on attendance as restrictive for insert with check (has_feature(''attendance''))';
  execute 'create policy plan_update on attendance as restrictive for update using (has_feature(''attendance''))';
  execute 'create policy plan_delete on attendance as restrictive for delete using (has_feature(''attendance''))';
end $$;

-- ------------------------------------------------------------
-- 3. Settings. The key is write-only to the screen, as Punchly asks:
--    it must never reach the browser bundle.
-- ------------------------------------------------------------
create or replace function get_punchly_settings() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s punchly_settings%rowtype;
begin
  if not can_view('payments') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  insert into punchly_settings (org_id) values (v_org) on conflict (org_id) do nothing;
  select * into s from punchly_settings where org_id = v_org;
  return jsonb_build_object(
    'is_enabled', s.is_enabled, 'api_url', s.api_url,
    'has_api_key', s.api_key is not null,
    'api_key_hint', case when s.api_key is null then null else '••••' || right(s.api_key, 4) end,
    'full_day_hours', s.full_day_hours, 'half_day_hours', s.half_day_hours,
    'auto_wage', s.auto_wage, 'store_location', s.store_location,
    'reconcile_days', s.reconcile_days, 'last_reconcile_at', s.last_reconcile_at,
    'backfill_from', s.backfill_from, 'last_sync_at', s.last_sync_at, 'last_sync_note', s.last_sync_note);
end $$;

create or replace function save_punchly_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not can_edit('payments') then raise exception 'Only a role with Payments edit rights can change these settings'; end if;
  perform require_feature('attendance');
  insert into punchly_settings (org_id) values (my_org_id()) on conflict (org_id) do nothing;
  update punchly_settings set
    api_url        = coalesce(nullif(p->>'api_url', ''), api_url),
    api_key        = case when nullif(p->>'api_key', '') is not null then p->>'api_key' else api_key end,
    is_enabled     = coalesce((p->>'is_enabled')::boolean, is_enabled),
    full_day_hours = coalesce(nullif(p->>'full_day_hours', '')::numeric, full_day_hours),
    half_day_hours = coalesce(nullif(p->>'half_day_hours', '')::numeric, half_day_hours),
    auto_wage      = coalesce((p->>'auto_wage')::boolean, auto_wage),
    store_location = coalesce((p->>'store_location')::boolean, store_location),
    reconcile_days = coalesce(nullif(p->>'reconcile_days', '')::integer, reconcile_days),
    backfill_from  = case when p ? 'backfill_from' then nullif(p->>'backfill_from', '')::date else backfill_from end,
    updated_at     = now()
  where org_id = my_org_id();
  return get_punchly_settings();
end $$;

/**
 * What the sync should ask Punchly for next. Three shapes, in order of precedence:
 *
 *   backfill  — history from backfill_from. The sync moves the marker along as each chunk
 *               lands, so a run that dies half way resumes where it stopped.
 *   reconcile — once every reconcile_days, one wider pull. Punchly's own advice: a day
 *               that has finished does not change on its own, but an admin can correct it
 *               afterwards, and nothing else would ever notice.
 *   ordinary  — yesterday and today. Yesterday because a phone out of signal at 08:42
 *               delivers its punch at 19:00, so a day is never finished on its first read.
 *
 * This hands back the raw key, so only the service role may call it.
 */
drop function if exists punchly_due(timestamptz);
create or replace function punchly_due(p_now timestamptz default now())
returns table (org_id uuid, api_url text, api_key text, from_date date, to_date date,
               is_backfill boolean, is_reconcile boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_today date := (p_now at time zone 'Asia/Kolkata')::date;
begin
  if not is_service_call() then raise exception 'Only the sync may read Punchly keys'; end if;
  return query
    with due as (
      select s.*, (s.backfill_from is not null) as backfill,
             (s.backfill_from is null
              and (s.last_reconcile_at is null or s.last_reconcile_at < p_now - make_interval(days => s.reconcile_days))) as reconcile
        from punchly_settings s
       where s.is_enabled and s.api_key is not null)
    select d.org_id, d.api_url, d.api_key,
           case when d.backfill then d.backfill_from
                when d.reconcile then v_today - d.reconcile_days
                else v_today - 1 end,
           v_today, d.backfill, d.reconcile
      from due d;
end $$;

/** A backfill chunk landed: move the marker past it, and clear it once history is caught up. */
create or replace function punchly_advance(p_org uuid, p_through date, p_now timestamptz default now()) returns date
language plpgsql security definer set search_path = public as $$
declare v_next date;
begin
  if not is_service_call() then raise exception 'Only the sync may move the backfill marker'; end if;
  v_next := case when p_through >= (p_now at time zone 'Asia/Kolkata')::date - 1 then null else p_through + 1 end;
  update punchly_settings set backfill_from = v_next, updated_at = now() where org_id = p_org;
  return v_next;
end $$;

-- ------------------------------------------------------------
-- 4. The roster. Auto-link on the Punchly user id, then on an exact
--    name, and hand back whatever is left for a human to match.
-- ------------------------------------------------------------
create or replace function upsert_punchly_staff(p_org uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb; v_id uuid; v_linked int := 0; v_named int := 0; v_unmatched jsonb := '[]'::jsonb;
begin
  if not is_service_call() and (p_org is distinct from my_org_id() or not has_role('owner', 'admin')) then
    raise exception 'Not allowed to sync this organisation';
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    select id into v_id from staff where org_id = p_org and punchly_user_id = r->>'user_id';
    if found then
      update staff set punchly_staff_id = r->>'staff_id', designation = coalesce(nullif(r->>'designation', ''), designation)
       where id = v_id;
      v_linked := v_linked + 1;
      continue;
    end if;
    -- not linked yet: one unambiguous name match is safe to take
    select s.id into v_id from staff s
     where s.org_id = p_org and s.punchly_user_id is null
       and lower(btrim(s.full_name)) = lower(btrim(r->>'full_name'))
     limit 2;
    if found and (select count(*) from staff s where s.org_id = p_org and s.punchly_user_id is null
                    and lower(btrim(s.full_name)) = lower(btrim(r->>'full_name'))) = 1 then
      update staff set punchly_user_id = r->>'user_id', punchly_staff_id = r->>'staff_id',
             designation = coalesce(nullif(r->>'designation', ''), designation)
       where id = v_id;
      v_named := v_named + 1;
    else
      v_unmatched := v_unmatched || jsonb_build_object('user_id', r->>'user_id', 'staff_id', r->>'staff_id', 'full_name', r->>'full_name');
    end if;
  end loop;
  return jsonb_build_object('linked', v_linked, 'matched_by_name', v_named,
                            'unmatched', v_unmatched, 'unmatched_count', jsonb_array_length(v_unmatched));
end $$;

/** Match a Punchly person to an ERP staff row by hand, from the screen. */
create or replace function link_punchly_staff(p_staff uuid, p_user_id text, p_staff_code text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  -- linking writes to the staff row, which is the owner's and the admin's to change
  if not has_role('owner', 'admin') then raise exception 'Only the owner or an admin can link staff to Punchly'; end if;
  perform require_feature('attendance');
  if nullif(p_user_id, '') is null then
    update staff set punchly_user_id = null, punchly_staff_id = null where id = p_staff and org_id = my_org_id();
  else
    update staff set punchly_user_id = p_user_id, punchly_staff_id = p_staff_code
     where id = p_staff and org_id = my_org_id();
  end if;
  if not found then raise exception 'Staff member not found'; end if;
end $$;

-- ------------------------------------------------------------
-- 5. Punches → one row a day. The whole fold lives here.
-- ------------------------------------------------------------
create or replace function upsert_punchly_attendance(p_org uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s punchly_settings%rowtype; rec record; v_written int := 0; v_kept int := 0; v_skipped int := 0;
        v_status attend_status; v_hours numeric; v_wage numeric; v_ot numeric;
begin
  if not is_service_call() and (p_org is distinct from my_org_id() or not can_edit('payments')) then
    raise exception 'Not allowed to sync this organisation';
  end if;
  select * into s from punchly_settings where org_id = p_org;
  if not found then raise exception 'Punchly is not set up for this organisation'; end if;

  for rec in
    with punch as (
      select x->>'staff_id' as code,
             nullif(x->>'punchly_user_id', '') as user_id,
             (x->>'attendance_date')::date as work_date,
             x->>'kind' as kind,
             (x->>'occurred_at')::timestamptz as at,
             nullif(x->>'branch_name', '') as branch_name,
             nullif(x->>'shift_name', '') as shift_name,
             nullif(x->>'latitude', '')::numeric as lat,
             nullif(x->>'longitude', '')::numeric as lon,
             coalesce(x->>'enforcement_status', 'ok') as enforcement
        from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x)
    select st.id as staff_id, st.daily_wage, p.work_date,
           min(p.at) filter (where p.kind = 'check_in') as first_in,
           max(p.at) filter (where p.kind = 'check_out') as last_out,
           count(*) as punches,
           (array_agg(p.branch_name) filter (where p.branch_name is not null))[1] as branch_name,
           (array_agg(p.shift_name) filter (where p.shift_name is not null))[1] as shift_name,
           (array_agg(p.lat) filter (where p.lat is not null))[1] as lat,
           (array_agg(p.lon) filter (where p.lon is not null))[1] as lon,
           bool_or(p.enforcement <> 'ok') as flagged
      from punch p
      join staff st on st.org_id = p_org
       and (st.punchly_user_id = p.user_id or (p.user_id is null and st.punchly_staff_id = p.code))
     group by st.id, st.daily_wage, p.work_date
  loop
    -- a row somebody typed by hand is the truth; the sync never argues with it
    if exists (select 1 from attendance a where a.staff_id = rec.staff_id and a.work_date = rec.work_date and a.source = 'manual') then
      v_kept := v_kept + 1;
      continue;
    end if;
    if rec.first_in is null and rec.last_out is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_hours := case when rec.first_in is not null and rec.last_out is not null and rec.last_out > rec.first_in
                    then round(extract(epoch from rec.last_out - rec.first_in) / 3600.0, 2) end;
    -- no check-out at all: they came, the phone did not record them leaving
    v_status := case when v_hours is null then 'present'
                     when v_hours >= s.full_day_hours then 'present'
                     else 'half_day' end;
    v_ot := case when v_hours is not null and v_hours > s.full_day_hours then round(v_hours - s.full_day_hours, 2) else 0 end;
    v_wage := case when not s.auto_wage then 0
                   when v_status = 'present' then coalesce(rec.daily_wage, 0)
                   else round(coalesce(rec.daily_wage, 0) / 2, 2) end;

    insert into attendance (org_id, staff_id, work_date, status, source,
                            in_time, out_time, first_in_at, last_out_at, worked_hours, ot_hours, wage_amount,
                            punches, branch_name, shift_name, latitude, longitude, needs_review, updated_at)
    values (p_org, rec.staff_id, rec.work_date, v_status, 'punchly',
            (rec.first_in at time zone 'Asia/Kolkata')::time, (rec.last_out at time zone 'Asia/Kolkata')::time,
            rec.first_in, rec.last_out, v_hours, v_ot, v_wage,
            rec.punches, rec.branch_name, rec.shift_name,
            case when s.store_location then rec.lat end, case when s.store_location then rec.lon end,
            rec.flagged or v_hours is null or (v_hours is not null and v_hours < s.half_day_hours), now())
    on conflict (staff_id, work_date) do update set
      status = excluded.status, source = 'punchly',
      in_time = excluded.in_time, out_time = excluded.out_time,
      first_in_at = excluded.first_in_at, last_out_at = excluded.last_out_at,
      worked_hours = excluded.worked_hours, ot_hours = excluded.ot_hours, wage_amount = excluded.wage_amount,
      punches = excluded.punches, branch_name = excluded.branch_name, shift_name = excluded.shift_name,
      latitude = excluded.latitude, longitude = excluded.longitude,
      needs_review = excluded.needs_review, updated_at = now();
    v_written := v_written + 1;
  end loop;

  update punchly_settings set last_sync_at = now(),
         last_sync_note = format('%s written, %s hand-typed rows kept, %s without a usable punch', v_written, v_kept, v_skipped)
   where org_id = p_org;
  return jsonb_build_object('written', v_written, 'kept_manual', v_kept, 'skipped', v_skipped);
end $$;

-- ------------------------------------------------------------
-- 6. What the screens read.
--
-- These are definer functions rather than views because only the owner
-- and admins may read the staff table, while an accountant is exactly
-- the person who runs the wage sheet. The plan, the module right and
-- the organisation are all checked here instead.
-- ------------------------------------------------------------
create or replace function attendance_register(p_from date, p_to date, p_staff uuid default null)
returns table (id uuid, staff_id uuid, full_name text, role staff_role, work_date date, status attend_status,
               source text, in_time time, out_time time, worked_hours numeric, ot_hours numeric,
               wage_amount numeric, punches integer, branch_name text, shift_name text,
               needs_review boolean, notes text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not can_view('payments') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  return query
    select a.id, a.staff_id, st.full_name, st.role, a.work_date, a.status, a.source,
           a.in_time, a.out_time, a.worked_hours, a.ot_hours, a.wage_amount, a.punches,
           a.branch_name, a.shift_name, a.needs_review, a.notes
      from attendance a
      join staff st on st.id = a.staff_id
     where a.org_id = my_org_id() and a.work_date between p_from and p_to
       and (p_staff is null or a.staff_id = p_staff)
     order by a.work_date desc, st.full_name;
end $$;

/** Days, hours and wages per person for a period — what a wage sheet is made of. */
create or replace function attendance_summary(p_from date, p_to date)
returns table (staff_id uuid, full_name text, role staff_role, is_mestry boolean, daily_wage numeric,
               present integer, half_days integer, absent integer, leave_days integer, holidays integer,
               worked_hours numeric, ot_hours numeric, wage numeric, needs_review integer)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not can_view('payments') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  return query
    select st.id, st.full_name, st.role, st.is_mestry, st.daily_wage,
           count(a.id) filter (where a.status = 'present')::int,
           count(a.id) filter (where a.status = 'half_day')::int,
           count(a.id) filter (where a.status = 'absent')::int,
           count(a.id) filter (where a.status = 'leave')::int,
           count(a.id) filter (where a.status = 'holiday')::int,
           round(coalesce(sum(a.worked_hours), 0), 2),
           round(coalesce(sum(a.ot_hours), 0), 2),
           round(coalesce(sum(a.wage_amount), 0), 2),
           count(a.id) filter (where a.needs_review)::int
      from staff st
      left join attendance a on a.staff_id = st.id and a.work_date between p_from and p_to
     where st.org_id = my_org_id() and st.is_active
     group by st.id, st.full_name, st.role, st.is_mestry, st.daily_wage
     order by st.full_name;
end $$;

/** The mapping screen: every staff member, and the Punchly person they are tied to. */
create or replace function punchly_roster()
returns table (id uuid, full_name text, role staff_role, is_mestry boolean, daily_wage numeric,
               designation text, punchly_user_id text, punchly_staff_id text, is_linked boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not has_role('owner', 'admin') then raise exception 'Only the owner or an admin can see the Punchly roster'; end if;
  perform require_feature('attendance');
  return query
    select st.id, st.full_name, st.role, st.is_mestry, st.daily_wage, st.designation,
           st.punchly_user_id, st.punchly_staff_id, (st.punchly_user_id is not null)
      from staff st where st.org_id = my_org_id() and st.is_active order by st.full_name;
end $$;

/** The sync writing back what happened — including the runs that failed. */
create or replace function punchly_note(p_org uuid, p_note text, p_ok boolean default true,
                                        p_reconciled boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_service_call() then raise exception 'Only the sync may write here'; end if;
  update punchly_settings
     set last_sync_note = p_note,
         last_sync_at = case when p_ok then now() else last_sync_at end,
         last_reconcile_at = case when p_ok and p_reconciled then now() else last_reconcile_at end,
         updated_at = now()
   where org_id = p_org;
end $$;

/**
 * An employee asks to be forgotten (DPDP). Removing the rows is not enough on its own —
 * the next sync would fetch them straight back — so the Punchly link goes with them, and
 * the person has to be matched again deliberately if they ever return.
 */
create or replace function forget_staff_attendance(p_staff uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if my_role() <> 'owner' then raise exception 'Only the owner can erase somebody''s attendance'; end if;
  perform require_feature('attendance');
  update staff set punchly_user_id = null, punchly_staff_id = null
   where id = p_staff and org_id = my_org_id();
  if not found then raise exception 'Staff member not found'; end if;
  delete from attendance where staff_id = p_staff and org_id = my_org_id();
  get diagnostics n = row_count;
  return n;
end $$;

/** Type a day in by hand. Marks the row manual, so no later sync overwrites it. */
create or replace function save_attendance(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid; v_status attend_status; v_wage numeric; s punchly_settings%rowtype;
begin
  if not can_edit('payments') then raise exception 'Only a role with Payments edit rights can change attendance'; end if;
  perform require_feature('attendance');
  v_status := coalesce(nullif(p->>'status', ''), 'present')::attend_status;
  select * into s from punchly_settings where org_id = v_org;
  v_wage := case when p ? 'wage_amount' then nullif(p->>'wage_amount', '')::numeric
                 when coalesce(s.auto_wage, true) and v_status = 'present'
                   then (select daily_wage from staff where id = (p->>'staff_id')::uuid)
                 when coalesce(s.auto_wage, true) and v_status = 'half_day'
                   then round((select coalesce(daily_wage, 0) from staff where id = (p->>'staff_id')::uuid) / 2, 2)
                 else 0 end;
  insert into attendance (org_id, staff_id, work_date, status, source, in_time, out_time, ot_hours, wage_amount, notes, updated_at)
  values (v_org, (p->>'staff_id')::uuid, coalesce(nullif(p->>'work_date', '')::date, current_date), v_status, 'manual',
          nullif(p->>'in_time', '')::time, nullif(p->>'out_time', '')::time,
          coalesce(nullif(p->>'ot_hours', '')::numeric, 0), coalesce(v_wage, 0), nullif(p->>'notes', ''), now())
  on conflict (staff_id, work_date) do update set
    status = excluded.status, source = 'manual', in_time = excluded.in_time, out_time = excluded.out_time,
    ot_hours = excluded.ot_hours, wage_amount = excluded.wage_amount, notes = excluded.notes,
    needs_review = false, updated_at = now()
  returning id into v_id;
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 7. The register travels with the rest of the org in a backup.
-- ------------------------------------------------------------
create or replace function snapshot_tables() returns text[]
language sql immutable as $$
  select array[
    'uoms', 'pack_types', 'item_categories', 'sections', 'items', 'item_price_overrides', 'price_lists', 'price_list_items:price_list_id:price_lists',
    'discount_schemes', 'item_barcodes', 'routes', 'customers', 'suppliers', 'stock_locations', 'vehicles', 'expense_heads', 'cash_bank_accounts', 'receipt_modes',
    'number_series', 'role_permissions', 'ledger_accounts', 'recipes', 'recipe_ingredients:recipe_id:recipes', 'production_batches', 'batch_ingredients:batch_id:production_batches',
    'item_batches', 'vehicle_trips', 'invoices', 'invoice_items:invoice_id:invoices', 'inbound_orders', 'quotations', 'quotation_items:quotation_id:quotations',
    'orders', 'order_items:order_id:orders', 'order_fulfilments', 'delivery_challans', 'challan_items:challan_id:delivery_challans',
    'purchases', 'purchase_items:purchase_id:purchases', 'purchase_returns', 'purchase_return_items:return_id:purchase_returns',
    'sales_returns', 'sales_return_items:return_id:sales_returns', 'receipts', 'receipt_lines:receipt_id:receipts', 'receipt_allocations:receipt_id:receipts',
    'payments', 'cheques', 'account_transfers', 'stock_transfers', 'stock_transfer_items:transfer_id:stock_transfers', 'stock_counts', 'stock_count_items:count_id:stock_counts',
    'stock_ledger', 'journal_entries', 'journal_lines:entry_id:journal_entries', 'account_transactions',
    'message_templates', 'reminder_rules', 'catalogs', 'broadcasts', 'new_stock_rules', 'message_log', 'transaction_message_settings', 'messaging_settings',
    'punchly_settings', 'print_templates', 'attendance', 'staff'
  ];
$$;
