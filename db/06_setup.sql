-- ============================================================
-- JYOTHI FOODS ERP — 06: FIRST RUN, PERMISSIONS, MODULE-LEVEL RLS
--
-- T0.3 / T0.4. Makes `role_permissions` the thing RLS actually
-- consults, so hiding a nav item is cosmetic and the database is
-- the boundary. Adds the one RPC a brand-new deployment needs to
-- create its org without a developer touching SQL.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Permission helpers. Owner can do everything; every other role
--    is looked up in role_permissions (a table the owner edits).
-- ------------------------------------------------------------
create or replace function can_view(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when my_role() = 'owner' then true
    else coalesce((select rp.can_view from role_permissions rp
                    where rp.org_id = my_org_id() and rp.role = my_role() and rp.module = p_module), false)
  end;
$$;

create or replace function can_edit(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when my_role() = 'owner' then true
    else coalesce((select rp.can_edit from role_permissions rp
                    where rp.org_id = my_org_id() and rp.role = my_role() and rp.module = p_module), false)
  end;
$$;

create or replace function can_delete(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when my_role() = 'owner' then true
    else coalesce((select rp.can_delete from role_permissions rp
                    where rp.org_id = my_org_id() and rp.role = my_role() and rp.module = p_module), false)
  end;
$$;

-- ------------------------------------------------------------
-- 2. Module-gated RLS.
--    READ is gated only where a role has no business seeing the
--    data at all (production, payments, purchases, messaging,
--    attendance). Masters and lookups stay readable by every staff
--    member because every transaction screen joins to them.
--    WRITE is gated by module everywhere.
-- ------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select * from (values
      -- table,                 module,       gate_read
      ('purchases',            'purchases',  true),
      ('payments',             'payments',   true),
      ('recipes',              'production', true),
      ('production_batches',   'production', true),
      ('message_templates',    'messaging',  true),
      ('message_log',          'messaging',  true),
      ('reminder_rules',       'messaging',  true),
      ('catalogs',             'messaging',  true),
      ('inbound_orders',       'messaging',  true),
      ('attendance',           'setup',      true),
      ('invoices',             'invoices',   false),
      ('sales_returns',        'returns',    false),
      ('receipts',             'receipts',   false),
      ('customers',            'customers',  false),
      ('items',                'items',      false),
      ('item_price_overrides', 'items',      false),
      ('item_categories',      'items',      false),
      ('vehicles',             'vehicles',   false),
      ('vehicle_trips',        'vehicles',   false),
      ('suppliers',            'purchases',  false),
      ('uoms',                 'setup',      false),
      ('pack_types',           'setup',      false),
      ('receipt_modes',        'setup',      false),
      ('expense_heads',        'setup',      false),
      ('sections',             'setup',      false),
      ('stock_locations',      'setup',      false),
      ('number_series',        'setup',      false),
      ('role_permissions',     'setup',      false),
      ('routes',               'setup',      false),
      ('import_jobs',          'setup',      false)
    ) as t(tbl, module, gate_read)
  loop
    execute format('drop policy if exists org_read on %I',  r.tbl);
    execute format('drop policy if exists org_write on %I', r.tbl);
    execute format('drop policy if exists items_write on %I', r.tbl);
    execute format('drop policy if exists payments_write on %I', r.tbl);
    execute format('drop policy if exists mod_insert on %I', r.tbl);
    execute format('drop policy if exists mod_update on %I', r.tbl);
    execute format('drop policy if exists mod_delete on %I', r.tbl);

    if r.gate_read then
      execute format('create policy org_read on %I for select using (org_id = my_org_id() and can_view(%L))', r.tbl, r.module);
    else
      execute format('create policy org_read on %I for select using (org_id = my_org_id())', r.tbl);
    end if;
    execute format('create policy mod_insert on %I for insert with check (org_id = my_org_id() and can_edit(%L))', r.tbl, r.module);
    execute format('create policy mod_update on %I for update using (org_id = my_org_id() and can_edit(%L)) with check (org_id = my_org_id() and can_edit(%L))', r.tbl, r.module, r.module);
    execute format('create policy mod_delete on %I for delete using (org_id = my_org_id() and can_delete(%L))', r.tbl, r.module);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 3. Document numbering must work for any role that can create the
--    document, not only for roles that can edit Setup. Definer
--    rights, but pinned to the caller's own org.
-- ------------------------------------------------------------
create or replace function next_doc_no(p_org uuid, p_doc_type text)
returns text language plpgsql security definer set search_path = public as $$
declare ns number_series%rowtype; v_reset boolean := false;
begin
  if p_org is distinct from my_org_id() then
    raise exception 'Cannot number documents for another organisation';
  end if;

  select * into ns from number_series
   where org_id = p_org and doc_type = p_doc_type for update;
  if not found then
    insert into number_series (org_id, doc_type) values (p_org, p_doc_type)
    returning * into ns;
  end if;

  v_reset := case ns.reset_period
    when 'yearly'  then ns.last_reset is null or date_trunc('year', ns.last_reset)  < date_trunc('year', current_date)
    when 'monthly' then ns.last_reset is null or date_trunc('month', ns.last_reset) < date_trunc('month', current_date)
    when 'daily'   then ns.last_reset is null or ns.last_reset < current_date
    else false end;

  if v_reset then
    update number_series set next_number = 1, last_reset = current_date where id = ns.id;
    ns.next_number := 1;
  end if;

  update number_series set next_number = ns.next_number + 1, last_reset = current_date
   where id = ns.id;

  return coalesce(ns.prefix,'') || lpad(ns.next_number::text, ns.width, '0') || coalesce(ns.suffix,'');
end $$;

-- ------------------------------------------------------------
-- 4. Default permission matrix (PROJECT_PLAN §2). Rows, not code:
--    the owner edits them in Setup → Users & permissions.
-- ------------------------------------------------------------
create or replace function seed_role_permissions(p_org uuid)
returns void language sql as $$
  insert into role_permissions (org_id, role, module, can_view, can_edit, can_delete)
  select p_org, r.role, m.module,
         -- admin: everything except deleting setup
         case when r.role = 'admin' then true
              when r.role = 'accountant'      then m.module in ('dashboard','customers','items','invoices','returns','receipts','payments','stock','reports','vehicles')
              when r.role = 'store_keeper'    then m.module in ('dashboard','items','purchases','stock','vehicles','reports')
              when r.role = 'production_head' then m.module in ('dashboard','items','stock','production','reports')
              when r.role = 'chief'           then m.module in ('dashboard','production')
              when r.role = 'driver'          then m.module in ('dashboard','invoices','receipts','vehicles')
              when r.role = 'sales_exec'      then m.module in ('dashboard','customers','items','invoices','returns','receipts','stock')
              else false end,
         case when r.role = 'admin' then true
              when r.role = 'accountant'      then m.module in ('customers','invoices','returns','receipts','payments')
              when r.role = 'store_keeper'    then m.module in ('items','purchases','stock','vehicles')
              when r.role = 'production_head' then m.module in ('production')
              when r.role = 'chief'           then m.module in ('production')
              when r.role = 'driver'          then m.module in ('receipts')
              when r.role = 'sales_exec'      then m.module in ('customers','invoices','receipts')
              else false end,
         case when r.role = 'admin' then m.module <> 'setup' else false end
  from unnest(enum_range(null::staff_role)) as r(role)
  cross join unnest(array['dashboard','items','customers','invoices','purchases','returns','receipts',
                          'payments','stock','production','vehicles','messaging','reports','setup']) as m(module)
  where r.role <> 'owner'
  on conflict (org_id, role, module) do nothing;
$$;

-- ------------------------------------------------------------
-- 5. First run. A signed-in user with no staff row creates the org
--    and becomes its owner. Disable public sign-ups in the Supabase
--    dashboard once the owner exists — every later user is created
--    from Setup → Users (edge function create-user).
-- ------------------------------------------------------------
create or replace function bootstrap_org(p_org_name text, p_full_name text, p_phone text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_org uuid;
begin
  if v_uid is null then
    raise exception 'Not signed in';
  end if;
  if exists (select 1 from staff where auth_uid = v_uid) then
    raise exception 'This login already belongs to an organisation';
  end if;
  if coalesce(trim(p_org_name), '') = '' then
    raise exception 'Organisation name is required';
  end if;

  insert into orgs (name) values (trim(p_org_name)) returning id into v_org;
  insert into staff (org_id, auth_uid, full_name, phone, role)
  values (v_org, v_uid, coalesce(nullif(trim(p_full_name), ''), 'Owner'), p_phone, 'owner');
  perform seed_role_permissions(v_org);
  return v_org;
end $$;

revoke execute on function bootstrap_org(text, text, text) from public, anon;
grant  execute on function bootstrap_org(text, text, text) to authenticated;

-- ------------------------------------------------------------
-- 6. Who am I — one round trip for the app shell: staff + org.
-- ------------------------------------------------------------
create or replace view v_me as
select s.id as staff_id, s.auth_uid, s.full_name, s.phone, s.role, s.is_mestry, s.is_active,
       o.id as org_id, o.name as org_name, o.address, o.phone as org_phone, o.fssai_no,
       o.breakage_recovery_pct, o.interest_pct_pa, o.credit_days, o.jurisdiction,
       o.license_valid_till
from staff s join orgs o on o.id = s.org_id
where s.auth_uid = auth.uid();

alter view v_me set (security_invoker = on);
