-- ============================================================
-- JYOTHI FOODS ERP — 10: STOCK REPORTS, TRIPS, VAN LOADING (T3)
-- Stock truth is still only stock_ledger. Everything below reads
-- it or appends to it. A van is a location; loading and unloading
-- are transfers between two locations.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Closing stock report, the client's STOCK_REPORT.xlsx:
--    grouped by section in sort order, in BOXES, negatives shown.
--    "Purchase" = everything that came in that day, "Sales" =
--    everything that went out, so closing = opening + in − out for
--    any mix of purchases, production, van loads and returns.
-- ------------------------------------------------------------
drop function if exists closing_stock_report(uuid, date, uuid);
create or replace function closing_stock_report(
  p_org uuid, p_date date default current_date, p_location uuid default null, p_section uuid default null
) returns table (
  section_id uuid, section_code text, section_name text, sort_order integer,
  item_id uuid, item_code text, pack text, item_name text, units_per_box integer,
  opening numeric, purchase numeric, sales numeric, closing numeric,
  opening_units numeric, closing_units numeric, is_negative boolean
) language sql stable as $$
  select sec.id, sec.code, coalesce(sec.name, 'OTHERS'), coalesce(sec.sort_order, 999),
         i.id, i.item_code, pt.code, i.name, i.units_per_box,
    round(coalesce(sum(sl.qty_base) filter (where sl.txn_date <  p_date), 0) / nullif(i.units_per_box, 0), 3),
    round(coalesce(sum(sl.qty_base) filter (where sl.txn_date =  p_date and sl.qty_base > 0), 0) / nullif(i.units_per_box, 0), 3),
    round(coalesce(-sum(sl.qty_base) filter (where sl.txn_date = p_date and sl.qty_base < 0), 0) / nullif(i.units_per_box, 0), 3),
    round(coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date), 0) / nullif(i.units_per_box, 0), 3),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <  p_date), 0),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date), 0),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date), 0) < 0
  from items i
  left join sections sec on sec.id = i.section_id
  left join pack_types pt on pt.id = i.pack_type_id
  left join stock_ledger sl on sl.item_id = i.id
       and (p_location is null or sl.location_id = p_location)
  where i.org_id = p_org and i.is_active and i.type = 'finished_good'
    and (p_section is null or i.section_id = p_section)
  group by sec.id, sec.code, sec.name, sec.sort_order, i.id, i.item_code, pt.code, i.name, i.units_per_box
  order by coalesce(sec.sort_order, 999), sec.name, i.item_code;
$$;

-- ------------------------------------------------------------
-- 2. Movement ledger for one item, with the document it came from
--    and a running balance.
-- ------------------------------------------------------------
create or replace function stock_movements(
  p_item uuid, p_from date default null, p_to date default null, p_location uuid default null
) returns table (
  id bigint, txn_date date, txn_type stock_txn_type, location_id uuid, location_name text,
  qty_base numeric, boxes numeric, balance_base numeric, balance_boxes numeric,
  rate numeric, ref_table text, ref_id uuid, ref_no text, created_at timestamptz
) language sql stable as $$
  with rows as (
    select sl.*, loc.name as location_name, i.units_per_box,
           case sl.ref_table
             when 'invoices'           then (select invoice_no from invoices where id = sl.ref_id)
             when 'purchases'          then (select coalesce(bill_no, 'purchase') from purchases where id = sl.ref_id)
             when 'sales_returns'      then (select return_no from sales_returns where id = sl.ref_id)
             when 'production_batches' then (select batch_no from production_batches where id = sl.ref_id)
             when 'vehicle_trips'      then (select 'Trip ' || to_char(trip_date, 'DD-MM') || ' ' || v.vehicle_number
                                             from vehicle_trips t join vehicles v on v.id = t.vehicle_id where t.id = sl.ref_id)
             when 'import'             then 'import'
             else sl.ref_table end as ref_no
    from stock_ledger sl
    join items i on i.id = sl.item_id
    join stock_locations loc on loc.id = sl.location_id
    where sl.item_id = p_item
      and (p_location is null or sl.location_id = p_location)
  )
  select r.id, r.txn_date, r.txn_type, r.location_id, r.location_name,
         r.qty_base, round(r.qty_base / nullif(r.units_per_box, 0), 3),
         sum(r.qty_base) over (order by r.txn_date, r.id) as balance_base,
         round(sum(r.qty_base) over (order by r.txn_date, r.id) / nullif(r.units_per_box, 0), 3),
         r.rate, r.ref_table, r.ref_id, r.ref_no, r.created_at
  from rows r
  where (p_from is null or r.txn_date >= p_from)
    and (p_to   is null or r.txn_date <= p_to)
  order by r.txn_date, r.id;
$$;

-- Item-level stock across all locations, for low-stock and the item list.
create or replace view v_item_stock as
select i.org_id, i.id as item_id, i.item_code, i.name, i.units_per_box, i.reorder_level, i.section_id, s.name as section_name,
       coalesce(sum(sl.qty_base), 0) as qty_base,
       round(coalesce(sum(sl.qty_base), 0) / nullif(i.units_per_box, 0), 3) as boxes,
       (coalesce(sum(sl.qty_base), 0) <= i.reorder_level) as is_low,
       (coalesce(sum(sl.qty_base), 0) < 0) as is_negative
from items i
left join sections s on s.id = i.section_id
left join stock_ledger sl on sl.item_id = i.id
where i.is_active
group by i.org_id, i.id, i.item_code, i.name, i.units_per_box, i.reorder_level, i.section_id, s.name;
alter view v_item_stock set (security_invoker = on);

-- ------------------------------------------------------------
-- 3. Trips. Status: planned → loaded → dispatched → settled.
-- ------------------------------------------------------------
create or replace view v_trip_list as
select t.id, t.org_id, t.trip_date, t.status, t.opening_km, t.closing_km, t.expenses, t.notes, t.created_at,
       t.vehicle_id, v.vehicle_number, v.location_id as van_location_id, l.name as van_location_name,
       t.driver_id, d.full_name as driver_name, t.route_id, r.name as route_name,
       coalesce((select sum(sl.qty_base / nullif(i.units_per_box, 0)) from stock_ledger sl join items i on i.id = sl.item_id
                  where sl.ref_table = 'vehicle_trips' and sl.ref_id = t.id and sl.txn_type = 'van_load' and sl.qty_base > 0), 0) as loaded_boxes,
       coalesce((select sum(total) from invoices inv where inv.trip_id = t.id and inv.status <> 'cancelled'), 0) as sold_value,
       coalesce((select count(*) from invoices inv where inv.trip_id = t.id and inv.status <> 'cancelled'), 0) as invoice_count,
       coalesce((select sum(total_amount) from receipts rc where rc.trip_id = t.id), 0) as collected
from vehicle_trips t
join vehicles v on v.id = t.vehicle_id
left join stock_locations l on l.id = v.location_id
left join staff d on d.id = t.driver_id
left join routes r on r.id = t.route_id;
alter view v_trip_list set (security_invoker = on);

create or replace function create_trip(p jsonb) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid; v_veh vehicles%rowtype;
begin
  select * into v_veh from vehicles where id = (p->>'vehicle_id')::uuid and org_id = v_org;
  if not found then raise exception 'Vehicle not found'; end if;
  if v_veh.location_id is null then raise exception 'Vehicle % has no stock location', v_veh.vehicle_number; end if;
  if exists (select 1 from vehicle_trips where vehicle_id = v_veh.id and status in ('planned','loaded','dispatched')) then
    raise exception 'Vehicle % already has an open trip — settle it first', v_veh.vehicle_number;
  end if;
  insert into vehicle_trips (org_id, vehicle_id, route_id, driver_id, trip_date, opening_km, notes)
  values (v_org, v_veh.id,
          coalesce(nullif(p->>'route_id','')::uuid, v_veh.route_id),
          coalesce(nullif(p->>'driver_id','')::uuid, v_veh.driver_id),
          coalesce(nullif(p->>'trip_date','')::date, current_date),
          nullif(p->>'opening_km','')::numeric, nullif(p->>'notes',''))
  returning id into v_id;
  return v_id;
end $$;

-- Lines: [{item_id, boxes}] — boxes convert with each item's own packing.
-- Replaces the 02 version (uom-based, no org guard). Godown → van.
drop function if exists van_load(uuid, uuid, uuid, jsonb);
create or replace function van_load(p_trip uuid, p_from_location uuid, p_lines jsonb)
returns void language plpgsql as $$
declare v_org uuid := my_org_id(); t vehicle_trips%rowtype; v_van uuid; l jsonb; it items%rowtype; q numeric; n int := 0;
begin
  select * into t from vehicle_trips where id = p_trip and org_id = v_org for update;
  if not found then raise exception 'Trip not found'; end if;
  if t.status not in ('planned','loaded') then raise exception 'Trip is %; loading is over', t.status; end if;
  select location_id into v_van from vehicles where id = t.vehicle_id;
  if p_from_location = v_van then raise exception 'Load from a godown, not the van itself'; end if;
  if not exists (select 1 from stock_locations where id = p_from_location and org_id = v_org) then raise exception 'Godown not found'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Nothing to load'; end if;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    select * into it from items where id = (l->>'item_id')::uuid and org_id = v_org;
    if not found then raise exception 'Line %: item not found', n; end if;
    q := round(coalesce((l->>'boxes')::numeric, 0) * it.units_per_box, 3);
    if q <= 0 then raise exception 'Line % (%): boxes must be greater than zero', n, it.item_code; end if;
    insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
    values (v_org, it.id, p_from_location, 'van_load', t.trip_date, -q, it.unit_rate, 'vehicle_trips', t.id, my_staff_id()),
           (v_org, it.id, v_van,           'van_load', t.trip_date,  q, it.unit_rate, 'vehicle_trips', t.id, my_staff_id());
  end loop;
  update vehicle_trips set status = 'loaded' where id = p_trip;
end $$;

-- Van → godown (unsold stock coming back). Lines: [{item_id, boxes}]; empty = everything still on the van.
create or replace function van_unload(p_trip uuid, p_to_location uuid, p_lines jsonb default '[]'::jsonb)
returns int language plpgsql as $$
declare v_org uuid := my_org_id(); t vehicle_trips%rowtype; v_van uuid; l jsonb; it items%rowtype; q numeric; n int := 0;
begin
  select * into t from vehicle_trips where id = p_trip and org_id = v_org for update;
  if not found then raise exception 'Trip not found'; end if;
  if t.status not in ('loaded','dispatched') then raise exception 'Trip is %; nothing to unload', t.status; end if;
  select location_id into v_van from vehicles where id = t.vehicle_id;
  if p_to_location = v_van then raise exception 'Unload to a godown, not the van itself'; end if;

  if jsonb_typeof(p_lines) = 'array' and jsonb_array_length(p_lines) > 0 then
    for l in select * from jsonb_array_elements(p_lines) loop
      select * into it from items where id = (l->>'item_id')::uuid and org_id = v_org;
      if not found then raise exception 'Item not found'; end if;
      q := round(coalesce((l->>'boxes')::numeric, 0) * it.units_per_box, 3);
      if q <= 0 then continue; end if;
      insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
      values (v_org, it.id, v_van,         'van_unload', current_date, -q, it.unit_rate, 'vehicle_trips', t.id, my_staff_id()),
             (v_org, it.id, p_to_location, 'van_unload', current_date,  q, it.unit_rate, 'vehicle_trips', t.id, my_staff_id());
      n := n + 1;
    end loop;
  else
    -- whatever is left on the van, item by item
    for it in
      select i.* from items i
      where i.org_id = v_org
        and coalesce((select sum(qty_base) from stock_ledger where item_id = i.id and location_id = v_van), 0) > 0
    loop
      select sum(qty_base) into q from stock_ledger where item_id = it.id and location_id = v_van;
      insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
      values (v_org, it.id, v_van,         'van_unload', current_date, -q, it.unit_rate, 'vehicle_trips', t.id, my_staff_id()),
             (v_org, it.id, p_to_location, 'van_unload', current_date,  q, it.unit_rate, 'vehicle_trips', t.id, my_staff_id());
      n := n + 1;
    end loop;
  end if;
  return n;
end $$;

create or replace function set_trip_status(p_trip uuid, p_status trip_status)
returns void language plpgsql as $$
declare t vehicle_trips%rowtype;
begin
  select * into t from vehicle_trips where id = p_trip and org_id = my_org_id() for update;
  if not found then raise exception 'Trip not found'; end if;
  if t.status = p_status then return; end if;
  if not (
       (t.status = 'planned'    and p_status in ('cancelled'))
    or (t.status = 'loaded'     and p_status in ('dispatched'))
    or (t.status = 'dispatched' and p_status in ('settled'))
  ) then
    raise exception 'Cannot move trip from % to %', t.status, p_status;
  end if;
  update vehicle_trips set status = p_status where id = p_trip;
end $$;

-- Day-end: unload what is left, record km and expenses, close the trip.
create or replace function settle_trip(p_trip uuid, p_to_location uuid, p_closing_km numeric default null,
                                       p_expenses numeric default null, p_notes text default null)
returns void language plpgsql as $$
declare t vehicle_trips%rowtype; v_van uuid; v_left numeric;
begin
  select * into t from vehicle_trips where id = p_trip and org_id = my_org_id() for update;
  if not found then raise exception 'Trip not found'; end if;
  if t.status not in ('loaded','dispatched') then raise exception 'Trip is %; cannot settle', t.status; end if;
  perform van_unload(p_trip, p_to_location, '[]'::jsonb);
  select location_id into v_van from vehicles where id = t.vehicle_id;
  select coalesce(sum(qty_base), 0) into v_left from stock_ledger where location_id = v_van;
  if v_left <> 0 then
    -- negative van stock (sold more than loaded) is allowed and flagged, never hidden
    raise notice 'Van still shows % base units after settlement', v_left;
  end if;
  update vehicle_trips
     set status = 'settled', closing_km = coalesce(p_closing_km, closing_km),
         expenses = coalesce(p_expenses, expenses), notes = coalesce(p_notes, notes)
   where id = p_trip;
end $$;

-- Per-item settlement: loaded vs sold vs returned, and the gap.
create or replace function trip_settlement(p_trip uuid)
returns table (
  item_id uuid, item_code text, item_name text, units_per_box integer,
  loaded numeric, sold numeric, returned numeric, gap numeric, sale_value numeric
) language sql stable as $$
  with t as (select vt.*, v.location_id as van from vehicle_trips vt join vehicles v on v.id = vt.vehicle_id where vt.id = p_trip),
  loads as (
    select sl.item_id, sum(sl.qty_base) as q from stock_ledger sl, t
    where sl.ref_table = 'vehicle_trips' and sl.ref_id = t.id and sl.txn_type = 'van_load' and sl.location_id = t.van group by sl.item_id),
  sales as (
    select ii.item_id, sum(ii.qty_base) as q, sum(ii.amount) as amt
    from invoices inv join invoice_items ii on ii.invoice_id = inv.id, t
    where inv.trip_id = t.id and inv.status <> 'cancelled' group by ii.item_id),
  unloads as (
    select sl.item_id, sum(sl.qty_base) as q from stock_ledger sl, t
    where sl.ref_table = 'vehicle_trips' and sl.ref_id = t.id and sl.txn_type = 'van_unload' and sl.location_id <> t.van group by sl.item_id)
  select i.id, i.item_code, i.name, i.units_per_box,
         round(coalesce(l.q, 0) / nullif(i.units_per_box, 0), 3),
         round(coalesce(s.q, 0) / nullif(i.units_per_box, 0), 3),
         round(coalesce(u.q, 0) / nullif(i.units_per_box, 0), 3),
         round((coalesce(l.q, 0) - coalesce(s.q, 0) - coalesce(u.q, 0)) / nullif(i.units_per_box, 0), 3),
         coalesce(s.amt, 0)
  from items i
  left join loads l on l.item_id = i.id
  left join sales s on s.item_id = i.id
  left join unloads u on u.item_id = i.id
  where l.item_id is not null or s.item_id is not null or u.item_id is not null
  order by i.item_code;
$$;

-- Loading sheet: what went on the van, in boxes.
create or replace function trip_loading_sheet(p_trip uuid)
returns table (item_id uuid, item_code text, item_name text, pack text, units_per_box integer, boxes numeric, units numeric, rate numeric)
language sql stable as $$
  select i.id, i.item_code, i.name, pt.code, i.units_per_box,
         round(sum(sl.qty_base) / nullif(i.units_per_box, 0), 3), sum(sl.qty_base), max(sl.rate)
  from stock_ledger sl
  join items i on i.id = sl.item_id
  left join pack_types pt on pt.id = i.pack_type_id
  join vehicle_trips t on t.id = sl.ref_id
  join vehicles v on v.id = t.vehicle_id
  where sl.ref_table = 'vehicle_trips' and sl.ref_id = p_trip and sl.txn_type = 'van_load' and sl.location_id = v.location_id
  group by i.id, i.item_code, i.name, pt.code, i.units_per_box
  order by i.item_code;
$$;

-- ------------------------------------------------------------
-- 4. Invoices sold from a van belong to a trip: the trip fixes the
--    vehicle and the stock location.
-- ------------------------------------------------------------
create or replace function save_invoice(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p_header->>'id', '')::uuid; v_status invoice_status; l jsonb; n int := 0;
        v_trip uuid := nullif(p_header->>'trip_id', '')::uuid; v_loc uuid; v_veh uuid; t record;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'An invoice needs at least one line';
  end if;

  v_loc := nullif(p_header->>'location_id', '')::uuid;
  v_veh := nullif(p_header->>'vehicle_id', '')::uuid;
  if v_trip is not null then
    select vt.status, vt.vehicle_id, v.location_id as van into t
      from vehicle_trips vt join vehicles v on v.id = vt.vehicle_id where vt.id = v_trip and vt.org_id = v_org;
    if not found then raise exception 'Trip not found'; end if;
    if t.status not in ('loaded','dispatched') then raise exception 'Trip is %; sales need a loaded or dispatched trip', t.status; end if;
    v_veh := t.vehicle_id;
    v_loc := t.van;
  end if;
  if v_loc is null then raise exception 'Choose where the stock leaves from'; end if;

  if v_id is null then
    insert into invoices (org_id, invoice_no, customer_id, invoice_date, location_id, vehicle_id, trip_id,
                          transport_name, lr_no, lr_date, freight, discount, round_off, notes, created_by)
    values (v_org, next_doc_no(v_org, 'invoice'),
            (p_header->>'customer_id')::uuid,
            coalesce(nullif(p_header->>'invoice_date','')::date, current_date),
            v_loc, v_veh, v_trip,
            nullif(p_header->>'transport_name',''), nullif(p_header->>'lr_no',''),
            nullif(p_header->>'lr_date','')::date,
            coalesce(nullif(p_header->>'freight','')::numeric, 0),
            coalesce(nullif(p_header->>'discount','')::numeric, 0),
            coalesce(nullif(p_header->>'round_off','')::numeric, 0),
            nullif(p_header->>'notes',''), my_staff_id())
    returning id into v_id;
  else
    select status into v_status from invoices where id = v_id and org_id = v_org;
    if v_status is null then raise exception 'Invoice not found'; end if;
    if v_status <> 'draft' then raise exception 'Invoice is %; only drafts can be edited', v_status; end if;
    update invoices set
      customer_id    = (p_header->>'customer_id')::uuid,
      invoice_date   = coalesce(nullif(p_header->>'invoice_date','')::date, invoice_date),
      location_id    = v_loc,
      vehicle_id     = v_veh,
      trip_id        = v_trip,
      transport_name = nullif(p_header->>'transport_name',''),
      lr_no          = nullif(p_header->>'lr_no',''),
      lr_date        = nullif(p_header->>'lr_date','')::date,
      freight        = coalesce(nullif(p_header->>'freight','')::numeric, 0),
      discount       = coalesce(nullif(p_header->>'discount','')::numeric, 0),
      round_off      = coalesce(nullif(p_header->>'round_off','')::numeric, 0),
      notes          = nullif(p_header->>'notes','')
    where id = v_id;
    delete from invoice_items where invoice_id = v_id;
  end if;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    if coalesce((l->>'boxes')::numeric, 0) <= 0 then
      raise exception 'Line %: boxes must be greater than zero', n;
    end if;
    insert into invoice_items (invoice_id, item_id, boxes, rate)
    values (v_id, (l->>'item_id')::uuid, (l->>'boxes')::numeric, nullif(l->>'rate','')::numeric);
  end loop;
  return v_id;
end $$;

-- Open trips a bill or receipt can be booked against.
create or replace view v_open_trips as
select * from v_trip_list where status in ('loaded','dispatched');
alter view v_open_trips set (security_invoker = on);
