-- ============================================================
-- JYOTHI FOODS ERP — 21: LICENCE PLANS (three keys)
--
-- One licence key per organisation already decides IF the app runs
-- (db/18_licensing.sql: trial → active → grace → expired). This file
-- adds WHAT it runs: the key also carries a plan, and the plan decides
-- which features are unlocked.
--
--   starter   billing and collection — the day-to-day counter work
--   growth    + the rest of the operation: buying, paying, returns,
--             production, vans, quotations / orders / challans / pricing
--   full      + everything automatic: WhatsApp and voice, batches and
--             barcodes, print designer, backup, audit, route profit,
--             incentives, the driver's phone, the desktop app
--
-- A fresh organisation is 'full' for its trial, so the client sees the
-- whole thing before buying; the key issued afterwards sets what was
-- actually paid for. Upgrading is one line — no reinstall, no new build.
--
-- Enforcement is the database's, not the screen's:
--   • can_view / can_edit / can_delete gain a plan test, so every
--     module-gated RLS policy already in the app is capped at once
--   • the finer features get restrictive RLS on their own tables, so a
--     locked feature cannot be written even by hand-made API calls
--   • the few functions that run as definer test the plan themselves
-- ============================================================

alter table orgs
  add column if not exists license_plan text not null default 'full'
    check (license_plan in ('starter', 'growth', 'full'));

/** What each plan includes. The single place a feature moves between plans. */
create or replace function plan_features(p_plan text) returns text[]
language sql immutable as $$
  select case p_plan
    when 'starter' then array['core']
    when 'growth'  then array['core', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents']
    else array['core', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents',
               'messaging', 'inventory', 'owner', 'insights', 'mobile', 'desktop']
  end;
$$;

create or replace function plan_label(p_plan text) returns text
language sql immutable as $$
  select case p_plan when 'starter' then 'Starter' when 'growth' then 'Growth' else 'Full' end;
$$;

/** Every feature the app knows, with the plan it first appears in — for the screen. */
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
    ('messaging',  'WhatsApp & calls',     'full',    'Templates, payment reminders, new-stock and catalog broadcasts, inbound orders, reminder and order-taking calls'),
    ('inventory',  'Batches & barcodes',   'full',    'Batch and expiry tracking, barcode labels, godown transfers, physical stock counts'),
    ('owner',      'Owner control',        'full',    'Print designer, backup and restore, audit trail'),
    ('insights',   'Profit & incentives',  'full',    'Route profitability and salesman incentive statements'),
    ('mobile',     'Driver''s phone',      'full',    'Van sales, on-the-spot receipts and delivery proof from a phone'),
    ('desktop',    'Desktop & offline',    'full',    'The installed Windows app, and working without a connection')
  ) as t(feature, label, plan, detail);
$$;

/** Which feature a module belongs to; the eight starter modules are 'core'. */
create or replace function module_feature(p_module text) returns text
language sql immutable as $$
  select case p_module
    when 'purchases'  then 'purchases'
    when 'returns'    then 'returns'
    when 'payments'   then 'payments'
    when 'production' then 'production'
    when 'vehicles'   then 'vehicles'
    when 'messaging'  then 'messaging'
    else 'core'
  end;
$$;

create or replace function my_plan() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select o.license_plan from orgs o where o.id = my_org_id()), 'starter');
$$;

/** Is this feature unlocked for the caller's organisation? The service role is never capped. */
create or replace function has_feature(p_feature text) returns boolean
language sql stable security definer set search_path = public as $$
  select is_service_call() or p_feature = any(plan_features(my_plan()));
$$;

-- ------------------------------------------------------------
-- 1. The plan caps every module-gated policy in the app at once.
-- ------------------------------------------------------------
create or replace function can_view(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_feature(module_feature(p_module)) and case
    when my_role() = 'owner' then true
    else coalesce((select rp.can_view from role_permissions rp
                    where rp.org_id = my_org_id() and rp.role = my_role() and rp.module = p_module), false)
  end;
$$;

create or replace function can_edit(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_feature(module_feature(p_module)) and case
    when my_role() = 'owner' then true
    else coalesce((select rp.can_edit from role_permissions rp
                    where rp.org_id = my_org_id() and rp.role = my_role() and rp.module = p_module), false)
  end;
$$;

create or replace function can_delete(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_feature(module_feature(p_module)) and case
    when my_role() = 'owner' then true
    else coalesce((select rp.can_delete from role_permissions rp
                    where rp.org_id = my_org_id() and rp.role = my_role() and rp.module = p_module), false)
  end;
$$;

-- ------------------------------------------------------------
-- 2. Features that live inside a module the plan already allows get
--    a restrictive policy on their own tables: reads stay (nothing a
--    client made in the trial disappears), writes stop.
-- ------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('quotations', 'documents'), ('quotation_items', 'documents'), ('orders', 'documents'), ('order_items', 'documents'),
    ('order_fulfilments', 'documents'), ('delivery_challans', 'documents'), ('challan_items', 'documents'),
    ('purchase_returns', 'documents'), ('purchase_return_items', 'documents'),
    ('price_lists', 'documents'), ('price_list_items', 'documents'), ('discount_schemes', 'documents'),
    ('item_batches', 'inventory'), ('item_barcodes', 'inventory'), ('stock_transfers', 'inventory'),
    ('stock_transfer_items', 'inventory'), ('stock_counts', 'inventory'), ('stock_count_items', 'inventory'),
    ('print_templates', 'owner'), ('backups', 'owner'), ('backup_settings', 'owner'),
    ('incentive_schemes', 'insights'),
    ('message_templates', 'messaging'), ('reminder_rules', 'messaging'), ('catalogs', 'messaging'),
    ('broadcasts', 'messaging'), ('new_stock_rules', 'messaging'), ('inbound_orders', 'messaging'),
    ('transaction_message_settings', 'messaging'), ('messaging_settings', 'messaging')
  ) as t(tbl, feature) loop
    if to_regclass('public.' || r.tbl) is null then continue; end if;
    execute format('drop policy if exists plan_insert on %I', r.tbl);
    execute format('drop policy if exists plan_update on %I', r.tbl);
    execute format('drop policy if exists plan_delete on %I', r.tbl);
    execute format('create policy plan_insert on %I as restrictive for insert with check (has_feature(%L))', r.tbl, r.feature);
    execute format('create policy plan_update on %I as restrictive for update using (has_feature(%L))', r.tbl, r.feature);
    execute format('create policy plan_delete on %I as restrictive for delete using (has_feature(%L))', r.tbl, r.feature);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 3. The functions that run as definer, or only read, test the plan
--    themselves — RLS on a table cannot speak for them.
-- ------------------------------------------------------------
create or replace function require_feature(p_feature text) returns void
language plpgsql stable security definer set search_path = public as $$
declare v_plan text; v_needs text;
begin
  if has_feature(p_feature) then return; end if;
  select f.plan, f.label into v_plan, v_needs from feature_catalogue() f where f.feature = p_feature;
  raise exception '% is not part of your % licence. It is included in the % plan.',
    coalesce(v_needs, p_feature), plan_label(my_plan()), plan_label(coalesce(v_plan, 'full'))
    using errcode = 'P0001', hint = 'plan_locked';
end $$;

create or replace function org_snapshot(p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; spec text; parts text[]; t text; v_rows jsonb; v_tables jsonb := '{}'::jsonb; v_order text;
begin
  if is_service_call() then
    v_org := p_org;
  else
    perform require_feature('owner');
    if my_role() <> 'owner' then raise exception 'Only the owner can take a backup'; end if;
    v_org := my_org_id();
  end if;
  if v_org is null then raise exception 'Organisation not known'; end if;
  foreach spec in array snapshot_tables() loop
    parts := string_to_array(spec, ':');
    t := parts[1];
    v_order := case t when 'ledger_accounts' then 'order by (t.parent_id is null) desc, t.name'
                      when 'journal_entries' then 'order by (t.reverses_entry_id is null) desc, t.created_at, t.entry_no'
                      when 'receipts' then 'order by (t.reversal_of is null) desc, t.created_at'
                      when 'payments' then 'order by (t.reversal_of is null) desc, t.created_at'
                      else 'order by t.ctid' end;
    if array_length(parts, 1) = 3 then
      execute format('select coalesce(jsonb_agg(to_jsonb(t) %s), ''[]''::jsonb) from %I t where exists (select 1 from %I p where p.id = t.%I and p.org_id = $1)', v_order, t, parts[3], parts[2]) into v_rows using v_org;
    else
      execute format('select coalesce(jsonb_agg(to_jsonb(t) %s), ''[]''::jsonb) from %I t where t.org_id = $1', v_order, t) into v_rows using v_org;
    end if;
    v_tables := v_tables || jsonb_build_object(t, v_rows);
  end loop;
  return jsonb_build_object('version', 1, 'taken_at', now(), 'org_id', v_org,
                            'org', (select to_jsonb(o) - 'license_key' from orgs o where o.id = v_org),
                            'tables', v_tables);
end $$;

create or replace function audit_search(p_from timestamptz default null, p_to timestamptz default null, p_table text default null, p_actor uuid default null, p_action text default null, p_search text default null, p_limit int default 200)
returns setof v_audit_log language plpgsql stable as $$
begin
  perform require_feature('owner');
  return query
    select * from v_audit_log a
     where a.org_id = my_org_id()
       and (p_from is null or a.created_at >= p_from) and (p_to is null or a.created_at <= p_to)
       and (p_table is null or a.table_name = p_table) and (p_actor is null or a.actor = p_actor)
       and (p_action is null or a.action = p_action)
       and (p_search is null or p_search = '' or a.row_id ilike '%' || p_search || '%' or coalesce(a.after::text, '') ilike '%' || p_search || '%' or coalesce(a.before::text, '') ilike '%' || p_search || '%')
     order by a.created_at desc, a.id desc
     limit least(coalesce(p_limit, 200), 1000);
end $$;

create or replace function mark_delivered(p_invoice uuid, p_photo text default null, p_receiver text default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare inv invoices%rowtype; v_driver uuid;
begin
  perform require_feature('mobile');
  select * into inv from invoices where id = p_invoice and org_id = my_org_id();
  if not found then raise exception 'Invoice not found'; end if;
  select driver_id into v_driver from vehicle_trips where id = inv.trip_id;
  if not (can_edit('invoices') or (v_driver is not null and v_driver = my_staff_id())) then
    raise exception 'Only the trip''s driver or an invoice editor can mark a delivery';
  end if;
  if inv.status in ('confirmed', 'dispatched') then
    perform set_invoice_status(p_invoice, 'delivered');
  elsif inv.status <> 'delivered' then
    raise exception 'Invoice % is %, not deliverable', inv.invoice_no, inv.status;
  end if;
  update invoices set delivered_at = now(), delivered_by = my_staff_id(),
         delivery_photo = coalesce(p_photo, delivery_photo), receiver_name = coalesce(nullif(p_receiver, ''), receiver_name),
         delivery_note = coalesce(nullif(p_note, ''), delivery_note)
   where id = p_invoice;
end $$;

create or replace function my_open_trip() returns setof v_trip_list
language plpgsql stable as $$
begin
  perform require_feature('mobile');
  return query
    select * from v_trip_list t
     where t.org_id = my_org_id() and t.driver_id = my_staff_id() and t.status in ('loaded', 'dispatched')
     order by t.trip_date desc, t.created_at desc limit 1;
end $$;

create or replace function trip_stops(p_trip uuid)
returns table (customer_id uuid, name text, town text, mobile1 text, address text, outstanding numeric, on_route boolean,
               bills integer, billed numeric, delivered integer, collected numeric, last_invoice_id uuid, pending_delivery uuid[])
language plpgsql stable as $$
-- every output column is a variable in here, so a bare column name would win over the
-- table's; use_column says the opposite, and the names below are qualified anyway
#variable_conflict use_column
begin
  perform require_feature('mobile');
  return query
  with t as (select * from vehicle_trips where id = p_trip),
  c as (
    select c.* from customers c, t where c.org_id = t.org_id and c.is_active and c.route_id = t.route_id
    union
    select c.* from customers c, t
     where c.id in (select i.customer_id from invoices i where i.trip_id = t.id
                    union select r.customer_id from receipts r where r.trip_id = t.id)),
  inv as (
    select i.customer_id, count(*) as bills, sum(i.total) as billed, count(*) filter (where i.status = 'delivered') as delivered,
           (array_agg(i.id order by i.created_at desc))[1] as last_id,
           array_remove(array_agg(i.id order by i.created_at) filter (where i.status in ('confirmed', 'dispatched')), null) as pending
      from invoices i, t where i.trip_id = t.id and i.status <> 'cancelled' group by 1),
  rc as (select r.customer_id, sum(r.total_amount) as collected from receipts r, t where r.trip_id = t.id group by 1)
  select c.id, c.name, c.town, c.mobile1, c.address, coalesce(o.outstanding, 0), (c.route_id = t.route_id),
         coalesce(inv.bills, 0)::int, coalesce(inv.billed, 0), coalesce(inv.delivered, 0)::int, coalesce(rc.collected, 0), inv.last_id,
         coalesce(inv.pending, '{}'::uuid[])
    from c cross join t
    left join v_customer_outstanding o on o.customer_id = c.id
    left join inv on inv.customer_id = c.id
    left join rc on rc.customer_id = c.id
   order by (coalesce(inv.bills, 0) > 0) desc, c.town, c.name;
end $$;

/** Route profitability and incentives read tables the plan already allows, so they ask here. */
create or replace function route_profitability(p_org uuid, p_from date, p_to date)
returns table (route_id uuid, route_name text, customers integer, trips integer, km numeric, invoices integer, boxes numeric,
               sales numeric, returns numeric, cogs numeric, gross_margin numeric, trip_expenses numeric, driver_wages numeric,
               net_profit numeric, margin_pct numeric, collection numeric, sales_per_km numeric)
language plpgsql stable as $$
#variable_conflict use_column
begin
  perform require_feature('insights');
  return query
  with cost as (
    select i.id as item_id,
           coalesce((select round(b.total_cost / nullif(b.actual_boxes * i.units_per_box, 0), 4) from production_batches b
                      where b.item_id = i.id and b.status = 'closed' and b.actual_boxes > 0 and b.production_date <= p_to
                      order by b.production_date desc, b.closed_at desc limit 1),
                    i.purchase_rate, 0) as unit_cost
      from items i where i.org_id = p_org),
  inv as (
    select i.id, coalesce(t.route_id, c.route_id) as route_id, i.total,
           (select coalesce(sum(ii.boxes), 0) from invoice_items ii where ii.invoice_id = i.id) as boxes,
           (select coalesce(sum(ii.qty * co.unit_cost), 0) from invoice_items ii join cost co on co.item_id = ii.item_id where ii.invoice_id = i.id) as cogs
      from invoices i
      join customers c on c.id = i.customer_id
      left join vehicle_trips t on t.id = i.trip_id
     where i.org_id = p_org and i.status <> 'cancelled' and i.invoice_date between p_from and p_to),
  by_inv as (select x.route_id, count(*) as n, sum(x.total) as sales, sum(x.boxes) as boxes, sum(x.cogs) as cogs from inv x group by 1),
  rets as (
    select coalesce(t.route_id, c.route_id) as route_id, sum(r.total) as returns
      from sales_returns r join customers c on c.id = r.customer_id
      left join invoices i on i.id = r.invoice_id left join vehicle_trips t on t.id = i.trip_id
     where r.org_id = p_org and r.return_date between p_from and p_to group by 1),
  coll as (
    select coalesce(t.route_id, c.route_id) as route_id, sum(r.total_amount) as collection
      from receipts r join customers c on c.id = r.customer_id left join vehicle_trips t on t.id = r.trip_id
     where r.org_id = p_org and r.receipt_date between p_from and p_to group by 1),
  -- named trp, not trips: an output column is called trips and plpgsql would see the variable
  trp as (
    select t.route_id, count(*) as n, sum(greatest(coalesce(t.closing_km, 0) - coalesce(t.opening_km, 0), 0)) as km,
           sum(coalesce(t.expenses, 0)) as expenses, sum(coalesce(d.daily_wage, 0)) as wages
      from vehicle_trips t left join staff d on d.id = t.driver_id
     where t.org_id = p_org and t.trip_date between p_from and p_to and t.status <> 'cancelled' group by 1),
  keys as (
    select r.id as route_id, r.name from routes r where r.org_id = p_org
    union select null::uuid, 'No route'),
  rows as (
    select k.route_id, k.name,
           (select count(*) from customers c where c.org_id = p_org and c.is_active and c.route_id is not distinct from k.route_id)::int as customers,
           coalesce(tr.n, 0)::int as trips, coalesce(tr.km, 0) as km, coalesce(bi.n, 0)::int as invoices, coalesce(bi.boxes, 0) as boxes,
           coalesce(bi.sales, 0) as sales, coalesce(rt.returns, 0) as returns, round(coalesce(bi.cogs, 0), 2) as cogs,
           coalesce(tr.expenses, 0) as trip_expenses, coalesce(tr.wages, 0) as driver_wages, coalesce(cl.collection, 0) as collection
      from keys k
      left join by_inv bi on bi.route_id is not distinct from k.route_id
      left join rets rt on rt.route_id is not distinct from k.route_id
      left join coll cl on cl.route_id is not distinct from k.route_id
      left join trp tr on tr.route_id is not distinct from k.route_id)
  select x.route_id, x.name, x.customers, x.trips, x.km, x.invoices, x.boxes, x.sales, x.returns, x.cogs,
         round(x.sales - x.returns - x.cogs, 2), x.trip_expenses, x.driver_wages,
         round(x.sales - x.returns - x.cogs - x.trip_expenses - x.driver_wages, 2),
         case when x.sales > 0 then round((x.sales - x.returns - x.cogs - x.trip_expenses - x.driver_wages) / x.sales * 100, 1) end,
         x.collection,
         case when x.km > 0 then round(x.sales / x.km, 2) end
    from rows x
   where x.sales <> 0 or x.trips <> 0 or x.collection <> 0 or x.route_id is not null
   order by 14 desc nulls last, x.name;
end $$;

create or replace function incentive_statement(p_org uuid, p_month date, p_staff uuid default null)
returns table (staff_id uuid, staff_name text, role staff_role, scheme_id uuid, scheme_name text, basis text, rate numeric,
               sales numeric, returns numeric, net_sales numeric, collection numeric, boxes numeric, new_customers integer,
               base_value numeric, earned numeric)
language plpgsql stable as $$
#variable_conflict use_column
begin
  perform require_feature('insights');
  return query
  with m as (select date_trunc('month', p_month)::date as d1, (date_trunc('month', p_month) + interval '1 month')::date as d2),
  sch as (select s.* from incentive_schemes s, m
           where s.org_id = p_org and s.is_active and (s.valid_from is null or s.valid_from < m.d2) and (s.valid_till is null or s.valid_till >= m.d1)),
  st as (select s.id, s.full_name, s.role from staff s where s.org_id = p_org and s.is_active and (p_staff is null or s.id = p_staff)),
  -- named sal, not sales: an output column is called sales and plpgsql would see the variable
  sal as (
    select i.sales_exec_id as sid, sum(i.total) as sales,
           sum((select coalesce(sum(ii.boxes), 0) from invoice_items ii where ii.invoice_id = i.id)) as boxes
      from invoices i, m
     where i.org_id = p_org and i.status <> 'cancelled' and i.invoice_date >= m.d1 and i.invoice_date < m.d2 and i.sales_exec_id is not null
     group by 1),
  rets as (
    select i.sales_exec_id as sid, sum(r.total) as returns
      from sales_returns r join invoices i on i.id = r.invoice_id, m
     where r.org_id = p_org and r.return_date >= m.d1 and r.return_date < m.d2 and i.sales_exec_id is not null
     group by 1),
  coll as (
    select r.collected_by as sid, sum(r.total_amount) as collection
      from receipts r, m
     where r.org_id = p_org and r.receipt_date >= m.d1 and r.receipt_date < m.d2 and r.collected_by is not null
     group by 1),
  firsts as (select i.customer_id, min(i.invoice_date) as first_date from invoices i where i.org_id = p_org and i.status <> 'cancelled' group by 1),
  newc as (
    select i.sales_exec_id as sid, count(distinct i.customer_id) as n
      from invoices i join firsts f on f.customer_id = i.customer_id and f.first_date = i.invoice_date, m
     where i.org_id = p_org and i.status <> 'cancelled' and f.first_date >= m.d1 and f.first_date < m.d2 and i.sales_exec_id is not null
     group by 1),
  base as (
    select st.id, st.full_name, st.role,
           coalesce(sal.sales, 0) as sales, coalesce(rets.returns, 0) as returns,
           coalesce(sal.sales, 0) - coalesce(rets.returns, 0) as net_sales,
           coalesce(coll.collection, 0) as collection, coalesce(sal.boxes, 0) as boxes, coalesce(newc.n, 0)::int as new_customers
      from st
      left join sal on sal.sid = st.id
      left join rets on rets.sid = st.id
      left join coll on coll.sid = st.id
      left join newc on newc.sid = st.id)
  select b.id, b.full_name, b.role, s.id, s.name, s.basis, s.rate,
         b.sales, b.returns, b.net_sales, b.collection, b.boxes, b.new_customers,
         bv.v,
         round(case s.basis
                 when 'sales_pct' then bv.v * s.rate / 100
                 when 'collection_pct' then bv.v * s.rate / 100
                 when 'per_box' then bv.v * s.rate
                 when 'per_new_customer' then bv.v * s.rate
                 when 'slab' then bv.v * coalesce((select (e->>'pct')::numeric from jsonb_array_elements(s.slabs) e
                                                    where bv.v >= (e->>'from')::numeric and (e->>'to' is null or bv.v < (e->>'to')::numeric)
                                                    order by (e->>'from')::numeric desc limit 1), 0) / 100
                 else 0 end, 2)
    from base b
    join sch s on b.role = any(s.roles)
    cross join lateral (select case s.basis when 'collection_pct' then b.collection when 'per_box' then b.boxes
                                            when 'per_new_customer' then b.new_customers::numeric else b.net_sales end as v) bv
   order by b.full_name, s.name;
end $$;

-- Voice calls are part of the messaging module but only in the Full plan.
create or replace function queue_message(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare c customers%rowtype; t message_templates; v_vars jsonb; v_body text; v_id uuid; v_to text; v_purpose msg_purpose; v_media text; v_channel channel_kind;
begin
  select * into c from customers where id = (p->>'customer_id')::uuid;
  if not found then raise exception 'Customer not found'; end if;
  if not is_service_call() and c.org_id is distinct from my_org_id() then
    raise exception 'Customer belongs to another organisation';
  end if;
  v_purpose := (p->>'purpose')::msg_purpose;
  v_channel := nullif(p->>'channel', '')::channel_kind;
  v_to := normalize_mobile(coalesce(nullif(p->>'to_number', ''), c.mobile1));
  if v_to is null or not c.whatsapp_opt_in then return null; end if;

  if nullif(p->>'template_id', '') is not null then
    select * into t from message_templates where id = (p->>'template_id')::uuid and org_id = c.org_id;
  else
    t := pick_template(c.org_id, v_purpose, c.language, coalesce(v_channel, 'whatsapp'));
  end if;
  v_channel := coalesce(v_channel, t.channel, 'whatsapp');
  if v_channel = 'ivr_call' then perform require_feature('messaging'); end if;

  v_vars := jsonb_build_object(
              'org', (select name from orgs where id = c.org_id),
              'name', c.name, 'town', coalesce(c.town, ''),
              'outstanding', to_char(coalesce((select outstanding from v_customer_outstanding where customer_id = c.id), 0), 'FM9,99,99,990.00'),
              'date', to_char(current_date, 'DD-MM-YYYY'),
              'last_items', coalesce((select string_agg(it.name || ' ' || trim(to_char(ii.boxes, 'FM9990.##')), ', ' order by ii.id)
                                        from invoice_items ii join items it on it.id = ii.item_id
                                       where ii.invoice_id = (select i.id from invoices i where i.customer_id = c.id and i.status <> 'cancelled'
                                                               order by i.invoice_date desc, i.created_at desc limit 1)), ''))
            || coalesce(p->'vars', '{}'::jsonb);
  v_body := coalesce(nullif(p->>'body', ''), render_template(t.body, v_vars));
  if v_body is null or v_body = '' then
    raise exception 'No active % % for %', v_purpose, case when v_channel = 'ivr_call' then 'call script' else 'template' end, c.name;
  end if;
  v_media := nullif(p->>'media_url', '');

  insert into message_log (org_id, customer_id, template_id, channel, purpose, to_number, body, payload, status,
                           ref_table, ref_id, rule_id, broadcast_id)
  values (c.org_id, c.id, t.id, v_channel, v_purpose, v_to, v_body,
          jsonb_strip_nulls(jsonb_build_object('vars', v_vars, 'media_url', v_media, 'kind', nullif(p->>'kind', ''),
                                               'template_name', t.provider_template_name, 'language', coalesce(t.language, c.language))),
          'queued', nullif(p->>'ref_table', ''), nullif(p->>'ref_id', '')::uuid,
          nullif(p->>'rule_id', '')::uuid, nullif(p->>'broadcast_id', '')::uuid)
  returning id into v_id;
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 4. The plan reaches the app, and the vendor sets it.
-- ------------------------------------------------------------
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
                            'this_device_known', known, 'checked_at', now(),
                            'plan', o.license_plan, 'plan_name', plan_label(o.license_plan),
                            'features', to_jsonb(plan_features(o.license_plan)),
                            'catalogue', (select jsonb_agg(to_jsonb(f)) from feature_catalogue() f));
end $$;

-- The plan is a new last argument, so the four-argument version has to go or every
-- existing four-argument call becomes ambiguous.
drop function if exists issue_license(uuid, date, text, integer);

create or replace function issue_license(p_org uuid, p_valid_till date, p_licensed_to text default null, p_max_devices integer default null, p_plan text default 'full') returns text
language plpgsql security definer set search_path = public as $$
declare v_key text; raw text;
begin
  if not is_service_call() then raise exception 'Licences are issued by the vendor only'; end if;
  if p_plan not in ('starter', 'growth', 'full') then raise exception 'Plan must be starter, growth or full'; end if;
  raw := upper(encode(gen_random_bytes(10), 'hex'));   -- 20 hex chars
  v_key := 'JF-' || substr(raw, 1, 5) || '-' || substr(raw, 6, 5) || '-' || substr(raw, 11, 5) || '-' || substr(raw, 16, 5);
  update orgs set license_key = license_hash(v_key), license_valid_till = p_valid_till,
                  licensed_to = coalesce(p_licensed_to, licensed_to), license_max_devices = coalesce(p_max_devices, license_max_devices),
                  license_plan = p_plan
   where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
  return v_key;
end $$;

/** Move an organisation up (or back) a plan without reissuing the key. */
create or replace function set_license_plan(p_org uuid, p_plan text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_service_call() then raise exception 'Plans are set by the vendor only'; end if;
  if p_plan not in ('starter', 'growth', 'full') then raise exception 'Plan must be starter, growth or full'; end if;
  update orgs set license_plan = p_plan where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
  return plan_label(p_plan);
end $$;

revoke execute on function issue_license(uuid, date, text, integer, text) from public, anon, authenticated;
revoke execute on function set_license_plan(uuid, text) from public, anon, authenticated;
