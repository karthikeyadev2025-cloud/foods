-- ============================================================
-- JYOTHI FOODS ERP — 19: PHASE 3a (T12)
-- Route profitability, salesman incentives, and what the driver's
-- phone needs: the trip's stops, van sales, on-the-spot receipts,
-- delivery proof. The two voice items wait for Hey Nikki's API.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Who sold it, who collected it, who delivered it
-- ------------------------------------------------------------
alter table customers add column if not exists sales_exec_id uuid references staff(id);
alter table invoices
  add column if not exists sales_exec_id uuid references staff(id),
  add column if not exists delivered_at timestamptz,
  add column if not exists delivered_by uuid references staff(id),
  add column if not exists delivery_photo text,        -- storage path in the proofs bucket
  add column if not exists receiver_name text,
  add column if not exists delivery_note text;
alter table receipts add column if not exists collected_by uuid references staff(id);
create index if not exists invoices_sales_exec_idx on invoices(org_id, sales_exec_id, invoice_date);
create index if not exists receipts_collected_by_idx on receipts(org_id, collected_by, receipt_date);

/** The invoice's salesman: given, else the customer's, else the sales exec / driver who made it. */
create or replace function stamp_sales_exec() returns trigger language plpgsql as $$
declare v_maker uuid := coalesce(new.created_by, my_staff_id());
begin
  if new.sales_exec_id is null then
    select c.sales_exec_id into new.sales_exec_id from customers c where c.id = new.customer_id;
    if new.sales_exec_id is null and exists (select 1 from staff s where s.id = v_maker and s.role in ('sales_exec', 'driver')) then
      new.sales_exec_id := v_maker;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists t_stamp_sales_exec on invoices;
create trigger t_stamp_sales_exec before insert on invoices for each row execute function stamp_sales_exec();

create or replace function stamp_collected_by() returns trigger language plpgsql as $$
begin
  new.collected_by := coalesce(new.collected_by, new.created_by, my_staff_id());
  return new;
end $$;
drop trigger if exists t_stamp_collected_by on receipts;
create trigger t_stamp_collected_by before insert on receipts for each row execute function stamp_collected_by();

create or replace view v_customer_list as
select c.id, c.org_id, c.code, c.name, c.mobile1, c.mobile2, c.mobile3, c.town, c.address,
       c.route_id, r.name as route_name, c.price_group, c.credit_limit, c.opening_balance,
       c.whatsapp_opt_in, c.is_active, c.created_at, c.price_list_id,
       coalesce(o.outstanding, 0) as outstanding,
       c.language,
       c.sales_exec_id, se.full_name as sales_exec_name
from customers c
left join routes r on r.id = c.route_id
left join staff se on se.id = c.sales_exec_id
left join v_customer_outstanding o on o.customer_id = c.id;
alter view v_customer_list set (security_invoker = on);

/** Give a salesman a whole route (or a list of customers) in one go. */
create or replace function assign_sales_exec(p_staff uuid, p_route uuid default null, p_customers uuid[] default null) returns integer
language plpgsql as $$
declare n int;
begin
  if not can_edit('customers') then raise exception 'Customer edit rights are needed'; end if;
  if p_route is null and p_customers is null then raise exception 'Give a route or a list of customers'; end if;
  update customers set sales_exec_id = p_staff
   where org_id = my_org_id() and ((p_route is not null and route_id = p_route) or (p_customers is not null and id = any(p_customers)));
  get diagnostics n = row_count;
  return n;
end $$;

-- ------------------------------------------------------------
-- 2. Incentive schemes and the monthly statement
-- ------------------------------------------------------------
create table if not exists incentive_schemes (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  name        text not null,
  /** sales_pct · collection_pct · per_box · per_new_customer · slab (pct by monthly net sales) */
  basis       text not null check (basis in ('sales_pct', 'collection_pct', 'per_box', 'per_new_customer', 'slab')),
  rate        numeric(12,4) not null default 0,
  /** slab: [{"from":0,"to":100000,"pct":0.5},{"from":100000,"pct":1}] — the slab reached applies to the whole month */
  slabs       jsonb not null default '[]'::jsonb,
  roles       staff_role[] not null default array['sales_exec', 'driver']::staff_role[],
  valid_from  date,
  valid_till  date,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (org_id, name)
);
alter table incentive_schemes enable row level security;
drop policy if exists org_read on incentive_schemes;
create policy org_read on incentive_schemes for select using (org_id = my_org_id());
drop policy if exists mod_insert on incentive_schemes;
create policy mod_insert on incentive_schemes for insert with check (org_id = my_org_id() and can_edit('setup'));
drop policy if exists mod_update on incentive_schemes;
create policy mod_update on incentive_schemes for update using (org_id = my_org_id() and can_edit('setup')) with check (org_id = my_org_id() and can_edit('setup'));
drop policy if exists mod_delete on incentive_schemes;
create policy mod_delete on incentive_schemes for delete using (org_id = my_org_id() and can_delete('setup'));
drop trigger if exists t_audit on incentive_schemes;
create trigger t_audit after insert or update or delete on incentive_schemes for each row execute function audit_row();

/**
 * One row per salesman per scheme for a month. Bases:
 *   sales      invoices stamped with the salesman (not cancelled), returns against those invoices taken off
 *   collection receipts the salesman collected (bounces come back as negatives, so they net off)
 *   boxes      boxes on those invoices
 *   new        customers whose first-ever invoice was that month, with this salesman
 */
create or replace function incentive_statement(p_org uuid, p_month date, p_staff uuid default null)
returns table (staff_id uuid, staff_name text, role staff_role, scheme_id uuid, scheme_name text, basis text, rate numeric,
               sales numeric, returns numeric, net_sales numeric, collection numeric, boxes numeric, new_customers integer,
               base_value numeric, earned numeric)
language sql stable as $$
  with m as (select date_trunc('month', p_month)::date as d1, (date_trunc('month', p_month) + interval '1 month')::date as d2),
  sch as (select s.* from incentive_schemes s, m
           where s.org_id = p_org and s.is_active and (s.valid_from is null or s.valid_from < m.d2) and (s.valid_till is null or s.valid_till >= m.d1)),
  st as (select s.id, s.full_name, s.role from staff s where s.org_id = p_org and s.is_active and (p_staff is null or s.id = p_staff)),
  sales as (
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
           coalesce(sales.sales, 0) as sales, coalesce(rets.returns, 0) as returns,
           coalesce(sales.sales, 0) - coalesce(rets.returns, 0) as net_sales,
           coalesce(coll.collection, 0) as collection, coalesce(sales.boxes, 0) as boxes, coalesce(newc.n, 0)::int as new_customers
      from st
      left join sales on sales.sid = st.id
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
$$;

-- ------------------------------------------------------------
-- 3. Route profitability
--    A sale belongs to the trip's route when it was sold from a van,
--    else to the customer's route. Cost is the latest closed batch
--    cost per unit (else the purchase rate), as in item_profit().
-- ------------------------------------------------------------
create or replace function route_profitability(p_org uuid, p_from date, p_to date)
returns table (route_id uuid, route_name text, customers integer, trips integer, km numeric, invoices integer, boxes numeric,
               sales numeric, returns numeric, cogs numeric, gross_margin numeric, trip_expenses numeric, driver_wages numeric,
               net_profit numeric, margin_pct numeric, collection numeric, sales_per_km numeric)
language sql stable as $$
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
  by_inv as (select route_id, count(*) as n, sum(total) as sales, sum(boxes) as boxes, sum(cogs) as cogs from inv group by 1),
  rets as (
    select coalesce(t.route_id, c.route_id) as route_id, sum(r.total) as returns
      from sales_returns r join customers c on c.id = r.customer_id
      left join invoices i on i.id = r.invoice_id left join vehicle_trips t on t.id = i.trip_id
     where r.org_id = p_org and r.return_date between p_from and p_to group by 1),
  coll as (
    select coalesce(t.route_id, c.route_id) as route_id, sum(r.total_amount) as collection
      from receipts r join customers c on c.id = r.customer_id left join vehicle_trips t on t.id = r.trip_id
     where r.org_id = p_org and r.receipt_date between p_from and p_to group by 1),
  trips as (
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
      left join trips tr on tr.route_id is not distinct from k.route_id)
  select x.route_id, x.name, x.customers, x.trips, x.km, x.invoices, x.boxes, x.sales, x.returns, x.cogs,
         round(x.sales - x.returns - x.cogs, 2) as gross_margin, x.trip_expenses, x.driver_wages,
         round(x.sales - x.returns - x.cogs - x.trip_expenses - x.driver_wages, 2) as net_profit,
         case when x.sales > 0 then round((x.sales - x.returns - x.cogs - x.trip_expenses - x.driver_wages) / x.sales * 100, 1) end as margin_pct,
         x.collection,
         case when x.km > 0 then round(x.sales / x.km, 2) end as sales_per_km
    from rows x
   where x.sales <> 0 or x.trips <> 0 or x.collection <> 0 or x.route_id is not null
   order by net_profit desc nulls last, x.name;
$$;

-- ------------------------------------------------------------
-- 4. The driver's phone
-- ------------------------------------------------------------
/** The signed-in driver's trip for today (loaded or on the road), newest first. */
create or replace function my_open_trip() returns setof v_trip_list
language sql stable as $$
  select * from v_trip_list t
   where t.org_id = my_org_id() and t.driver_id = my_staff_id() and t.status in ('loaded', 'dispatched')
   order by t.trip_date desc, t.created_at desc limit 1;
$$;

/**
 * The stops on a trip: every active customer on its route, with what happened to them
 * today on this trip. Customers billed on the trip but off the route are included.
 */
create or replace function trip_stops(p_trip uuid)
returns table (customer_id uuid, name text, town text, mobile1 text, address text, outstanding numeric, on_route boolean,
               bills integer, billed numeric, delivered integer, collected numeric, last_invoice_id uuid, pending_delivery uuid[])
language sql stable as $$
  with t as (select * from vehicle_trips where id = p_trip),
  c as (
    select c.* from customers c, t where c.org_id = t.org_id and c.is_active and c.route_id = t.route_id
    union
    select c.* from customers c, t where c.id in (select customer_id from invoices where trip_id = t.id union select customer_id from receipts where trip_id = t.id)),
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
$$;

/**
 * Delivery proof from the phone. The trip's driver may mark their own trip's invoices
 * delivered even without invoice edit rights; anyone with invoice edit rights may too.
 */
create or replace function mark_delivered(p_invoice uuid, p_photo text default null, p_receiver text default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare inv invoices%rowtype; v_driver uuid;
begin
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

-- A driver sells from the van and collects: invoices edit is now part of the driver's defaults.
update role_permissions set can_edit = true where role = 'driver' and module = 'invoices';

create or replace function seed_role_permissions(p_org uuid)
returns void language sql as $$
  insert into role_permissions (org_id, role, module, can_view, can_edit, can_delete)
  select p_org, r.role, m.module,
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
              when r.role = 'driver'          then m.module in ('invoices','receipts')
              when r.role = 'sales_exec'      then m.module in ('customers','invoices','receipts')
              else false end,
         case when r.role = 'admin' then m.module <> 'setup' else false end
  from unnest(enum_range(null::staff_role)) as r(role)
  cross join unnest(array['dashboard','items','customers','invoices','purchases','returns','receipts',
                          'payments','stock','production','vehicles','messaging','reports','setup']) as m(module)
  where r.role <> 'owner'
  on conflict (org_id, role, module) do nothing;
$$;
