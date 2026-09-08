-- ============================================================
-- JYOTHI FOODS ERP — 27: ATTENDANCE BELONGS IN STARTER
--
-- A shop that only bills and collects still pays its staff, so the register
-- and the wage sheet go into the cheapest plan.
--
-- Moving the feature is one word. The reason this file is longer than one word
-- is that attendance was riding on the PAYMENTS module — the accountant's
-- module — and every module-gated policy asks can_view(module) BEFORE it asks
-- about the plan. Starter has no Payments, so the rows would stay hidden with
-- the feature switched on and nothing to explain why.
--
-- So attendance becomes a module of its own. That is the honest shape anyway:
-- who may see wages is a different question from who may see the cash book,
-- and until now they could not be answered separately.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Starter gets it. Everything above still includes it.
-- ------------------------------------------------------------
create or replace function plan_features(p_plan text) returns text[]
language sql immutable as $$
  select case p_plan
    when 'starter' then array['core', 'attendance']
    when 'growth'  then array['core', 'attendance', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents']
    else array['core', 'attendance', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents',
               'messaging', 'inventory', 'owner', 'insights', 'mobile', 'desktop']
  end;
$$;

create or replace function feature_catalogue()
returns table (feature text, label text, plan text, detail text)
language sql immutable as $$
  select * from (values
    ('core',       'Billing & collection', 'starter', 'Items, customers, invoices and prints, receipts, stock on hand, the day''s reports, setup and users'),
    ('attendance', 'Attendance & wages',   'starter', 'The daily register, hours and wages per staff, and the Punchly phone-punch sync'),
    ('purchases',  'Purchases',            'growth',  'Supplier bills, suppliers, purchase returns'),
    ('returns',    'Sales returns',        'growth',  'Fresh return, rate difference and damage return'),
    ('payments',   'Payments & accounts',  'growth',  'Payments, expenses, cash and bank books, cheques, journal, trial balance, P&L, balance sheet'),
    ('production', 'Production',           'growth',  'Recipes, batches, chief actuals, variance'),
    ('vehicles',   'Vans & trips',         'growth',  'Trips, van loading, loading sheet, settlement'),
    ('documents',  'Quotations & pricing', 'growth',  'Quotations, sale and purchase orders, delivery challans, price lists, discount schemes'),
    ('messaging',  'WhatsApp & calls',     'full',    'Templates, payment reminders, new-stock and catalog broadcasts, inbound orders, reminder and order-taking calls'),
    ('inventory',  'Batches & barcodes',   'full',    'Batch and expiry tracking, barcode labels, godown transfers, physical stock counts'),
    ('owner',      'Owner control',        'full',    'Print designer, backup and restore, audit trail'),
    ('insights',   'Profit & incentives',  'full',    'Route profitability and salesman incentive statements'),
    ('mobile',     'Driver''s phone',      'full',    'Van sales, on-the-spot receipts and delivery proof from a phone'),
    ('desktop',    'Desktop & offline',    'full',    'The installed Windows app, and working without a connection')
  ) as t(feature, label, plan, detail);
$$;

/** Attendance is now its own module, so it is no longer 'core' by default. */
create or replace function module_feature(p_module text) returns text
language sql immutable as $$
  select case p_module
    when 'purchases'  then 'purchases'
    when 'returns'    then 'returns'
    when 'payments'   then 'payments'
    when 'production' then 'production'
    when 'vehicles'   then 'vehicles'
    when 'messaging'  then 'messaging'
    when 'attendance' then 'attendance'
    else 'core'
  end;
$$;

-- ------------------------------------------------------------
-- 2. Who may see wages, asked separately from who may see the books
-- ------------------------------------------------------------
create or replace function seed_role_permissions(p_org uuid)
returns void language sql as $$
  insert into role_permissions (org_id, role, module, can_view, can_edit, can_delete)
  select p_org, r.role, m.module,
         case when r.role = 'admin' then true
              when r.role = 'accountant'      then m.module in ('dashboard','customers','items','invoices','returns','receipts','payments','stock','reports','vehicles','attendance')
              when r.role = 'store_keeper'    then m.module in ('dashboard','items','purchases','stock','vehicles','reports')
              when r.role = 'production_head' then m.module in ('dashboard','items','stock','production','reports')
              when r.role = 'chief'           then m.module in ('dashboard','production')
              when r.role = 'driver'          then m.module in ('dashboard','invoices','receipts','vehicles')
              when r.role = 'sales_exec'      then m.module in ('dashboard','customers','items','invoices','returns','receipts','stock')
              else false end,
         case when r.role = 'admin' then true
              when r.role = 'accountant'      then m.module in ('customers','invoices','returns','receipts','payments','attendance')
              when r.role = 'store_keeper'    then m.module in ('items','purchases','stock','vehicles')
              when r.role = 'production_head' then m.module in ('production')
              when r.role = 'chief'           then m.module in ('production')
              when r.role = 'driver'          then m.module in ('invoices','receipts')
              when r.role = 'sales_exec'      then m.module in ('customers','invoices','receipts')
              else false end,
         case when r.role = 'admin' then m.module <> 'setup' else false end
  from unnest(enum_range(null::staff_role)) as r(role)
  cross join unnest(array['dashboard','items','customers','invoices','purchases','returns','receipts',
                          'payments','stock','production','vehicles','messaging','reports','setup','attendance']) as m(module)
  where r.role <> 'owner'
  on conflict (org_id, role, module) do nothing;
$$;

/**
 * Every organisation that already exists predates the module, so it has no rows
 * for it and every non-owner would be locked out. seed_role_permissions only
 * inserts what is missing, so running it again is exactly the backfill needed.
 */
do $$
declare o record;
begin
  for o in select id from orgs loop
    perform seed_role_permissions(o.id);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 3. The policies and the functions ask about attendance now
-- ------------------------------------------------------------
do $$
begin
  execute 'drop policy if exists org_read on attendance';
  execute 'drop policy if exists mod_insert on attendance';
  execute 'drop policy if exists mod_update on attendance';
  execute 'drop policy if exists mod_delete on attendance';
  execute 'create policy org_read on attendance for select using (org_id = my_org_id() and can_view(''attendance''))';
  execute 'create policy mod_insert on attendance for insert with check (org_id = my_org_id() and can_edit(''attendance''))';
  execute 'create policy mod_update on attendance for update using (org_id = my_org_id() and can_edit(''attendance'')) with check (org_id = my_org_id() and can_edit(''attendance''))';
  execute 'create policy mod_delete on attendance for delete using (org_id = my_org_id() and can_delete(''attendance''))';
end $$;

create or replace function get_punchly_settings() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s punchly_settings%rowtype;
begin
  if not can_view('attendance') then raise exception 'Attendance is not available to your role'; end if;
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
  if not can_edit('attendance') then raise exception 'Only a role with Attendance edit rights can change these settings'; end if;
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

create or replace function attendance_register(p_from date, p_to date, p_staff uuid default null)
returns table (id uuid, staff_id uuid, full_name text, role staff_role, work_date date, status attend_status,
               source text, in_time time, out_time time, worked_hours numeric, ot_hours numeric,
               wage_amount numeric, punches integer, branch_name text, shift_name text,
               needs_review boolean, notes text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not can_view('attendance') then raise exception 'Attendance is not available to your role'; end if;
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

create or replace function attendance_summary(p_from date, p_to date)
returns table (staff_id uuid, full_name text, role staff_role, is_mestry boolean, daily_wage numeric,
               present integer, half_days integer, absent integer, leave_days integer, holidays integer,
               worked_hours numeric, ot_hours numeric, wage numeric, needs_review integer)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not can_view('attendance') then raise exception 'Attendance is not available to your role'; end if;
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

create or replace function save_attendance(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid; v_status attend_status; v_wage numeric; s punchly_settings%rowtype;
begin
  if not can_edit('attendance') then raise exception 'Only a role with Attendance edit rights can change attendance'; end if;
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
