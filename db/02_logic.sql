-- ============================================================
-- JYOTHI FOODS ERP — BUSINESS LOGIC
-- Nothing here hard-codes a unit, a mode or a number. Conversion
-- reads the client's own `uoms` rows; modes read `receipt_modes`.
-- ============================================================

-- ------------------------------------------------------------
-- A. UNIT CONVERSION
--    Everything normalises through PIECES, using the item's own
--    units_per_box / pieces_per_unit set on Add Product.
-- ------------------------------------------------------------
create or replace function qty_to_pieces(p_item uuid, p_qty numeric, p_uom uuid)
returns numeric language plpgsql stable as $$
declare it items%rowtype; u uoms%rowtype;
begin
  select * into it from items where id = p_item;
  if not found then raise exception 'Item % not found', p_item; end if;
  select * into u from uoms where id = p_uom;
  if not found then raise exception 'UOM % not found', p_uom; end if;

  return case u.basis
    when 'box'    then p_qty * it.units_per_box * it.pieces_per_unit
    when 'unit'   then p_qty * it.pieces_per_unit
    when 'piece'  then p_qty
    when 'weight' then case
                         when coalesce(it.net_weight_g,0) > 0
                         then (p_qty * coalesce(u.weight_g,1)) / it.net_weight_g
                         else p_qty * coalesce(u.weight_g,1) / 1000
                       end
  end;
end $$;

create or replace function pieces_to_uom(p_item uuid, p_pieces numeric, p_uom uuid)
returns numeric language plpgsql stable as $$
declare it items%rowtype; u uoms%rowtype;
begin
  select * into it from items where id = p_item;
  select * into u  from uoms  where id = p_uom;

  return case u.basis
    when 'box'    then p_pieces / nullif(it.units_per_box * it.pieces_per_unit,0)
    when 'unit'   then p_pieces / nullif(it.pieces_per_unit,0)
    when 'piece'  then p_pieces
    when 'weight' then case
                         when coalesce(it.net_weight_g,0) > 0
                         then (p_pieces * it.net_weight_g) / nullif(u.weight_g,0)
                         else p_pieces
                       end
  end;
end $$;

-- Convert an entered quantity into the item's own stock-keeping uom
create or replace function to_base_qty(p_item uuid, p_qty numeric, p_uom uuid)
returns numeric language sql stable as $$
  select pieces_to_uom(p_item, qty_to_pieces(p_item, p_qty, p_uom),
                       (select base_uom_id from items where id = p_item));
$$;

-- Effective selling rate per UNIT for a customer on a date
create or replace function effective_unit_rate(p_item uuid, p_customer uuid,
                                               p_date date default current_date)
returns numeric language sql stable as $$
  select coalesce(
    (select o.unit_rate from item_price_overrides o
      where o.item_id = p_item and o.customer_id = p_customer
        and p_date between o.valid_from and coalesce(o.valid_to, p_date)
      order by o.valid_from desc limit 1),
    (select o.unit_rate from item_price_overrides o
       join customers c on c.price_group = o.price_group
      where o.item_id = p_item and c.id = p_customer
        and p_date between o.valid_from and coalesce(o.valid_to, p_date)
      order by o.valid_from desc limit 1),
    (select i.unit_rate from items i where i.id = p_item)
  );
$$;

-- ------------------------------------------------------------
-- B. DOCUMENT NUMBERING — series are configured, not hard-coded
-- ------------------------------------------------------------
create or replace function next_doc_no(p_org uuid, p_doc_type text)
returns text language plpgsql as $$
declare ns number_series%rowtype; v_reset boolean := false;
begin
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
-- C. LINE CALCULATION
--    Invoice: the operator types CODE, Boxes, Rate. Nothing else.
--    Qty = boxes x units_per_box   |   Total = Qty x rate
-- ------------------------------------------------------------
create or replace function trg_fill_qty_base() returns trigger language plpgsql as $$
begin
  new.qty_base := to_base_qty(new.item_id, new.qty, new.uom_id);
  return new;
end $$;

create or replace function trg_invoice_line() returns trigger language plpgsql as $$
declare it items%rowtype;
begin
  select * into it from items where id = new.item_id;
  -- packing and uom are SNAPSHOTTED from the master, never typed on this screen
  if coalesce(new.units_per_box,0) = 0 then new.units_per_box := it.units_per_box; end if;
  new.uom_id   := coalesce(new.uom_id, it.base_uom_id);
  new.qty      := new.boxes * new.units_per_box;
  new.qty_base := to_base_qty(new.item_id, new.qty, new.uom_id);
  new.amount   := round(new.qty * new.rate, 2);
  return new;
end $$;

create trigger t_invoice_items_calc  before insert or update on invoice_items
  for each row execute function trg_invoice_line();
create trigger t_purchase_items_base before insert or update on purchase_items
  for each row execute function trg_fill_qty_base();
create trigger t_return_items_base   before insert or update on sales_return_items
  for each row execute function trg_fill_qty_base();

-- ------------------------------------------------------------
-- D. STOCK POSTING
-- ------------------------------------------------------------
create or replace function post_invoice_stock(p_invoice uuid)
returns void language plpgsql as $$
declare inv invoices%rowtype;
begin
  select * into inv from invoices where id = p_invoice;
  delete from stock_ledger where ref_table = 'invoices' and ref_id = p_invoice;
  if inv.status in ('draft','cancelled') then return; end if;

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select inv.org_id, ii.item_id, inv.location_id, 'sale', inv.invoice_date,
         -ii.qty_base, ii.rate, 'invoices', inv.id, inv.created_by
  from invoice_items ii where ii.invoice_id = p_invoice;
end $$;

create or replace function trg_invoice_post() returns trigger language plpgsql as $$
begin perform post_invoice_stock(new.id); return new; end $$;

create trigger t_invoice_post after insert or update of status on invoices
  for each row execute function trg_invoice_post();

create or replace function post_purchase_stock(p_purchase uuid)
returns void language plpgsql as $$
declare p purchases%rowtype;
begin
  select * into p from purchases where id = p_purchase;
  delete from stock_ledger where ref_table='purchases' and ref_id=p_purchase;
  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select p.org_id, pi.item_id, p.location_id, 'purchase', p.bill_date,
         pi.qty_base, pi.rate, 'purchases', p.id, p.created_by
  from purchase_items pi where pi.purchase_id = p_purchase;
end $$;

-- fresh_return brings stock back; damage_return writes it off; rate_difference
-- touches no stock at all. Breakage is credited at orgs.breakage_recovery_pct.
create or replace function post_return_stock(p_return uuid)
returns void language plpgsql as $$
declare r sales_returns%rowtype;
begin
  select * into r from sales_returns where id = p_return;
  delete from stock_ledger where ref_table='sales_returns' and ref_id=p_return;
  if r.kind = 'rate_difference' or r.location_id is null then return; end if;

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select r.org_id, ri.item_id, r.location_id,
         case when r.kind = 'fresh_return' then 'sale_return'::stock_txn_type
              else 'damage'::stock_txn_type end,
         r.return_date,
         case when r.kind = 'fresh_return' then ri.qty_base else 0 end,
         coalesce(ri.new_rate, ri.old_rate, 0), 'sales_returns', r.id, r.created_by
  from sales_return_items ri where ri.return_id = p_return;
end $$;

create or replace function breakage_credit(p_org uuid, p_value numeric)
returns numeric language sql stable as $$
  select round(p_value * (select breakage_recovery_pct from orgs where id = p_org) / 100, 2);
$$;

create or replace function van_load(
  p_org uuid, p_trip uuid, p_from_location uuid, p_lines jsonb
) returns void language plpgsql as $$
declare v_loc uuid; l jsonb; q numeric;
begin
  select vh.location_id into v_loc
    from vehicle_trips t join vehicles vh on vh.id = t.vehicle_id where t.id = p_trip;

  for l in select * from jsonb_array_elements(p_lines) loop
    q := to_base_qty((l->>'item_id')::uuid, (l->>'qty')::numeric, (l->>'uom_id')::uuid);
    insert into stock_ledger (org_id,item_id,location_id,txn_type,qty_base,ref_table,ref_id)
    values (p_org,(l->>'item_id')::uuid,p_from_location,'van_load',-q,'vehicle_trips',p_trip),
           (p_org,(l->>'item_id')::uuid,v_loc,'van_load',q,'vehicle_trips',p_trip);
  end loop;

  update vehicle_trips set status='loaded' where id = p_trip;
end $$;

-- ------------------------------------------------------------
-- E. STOCK REPORTS
-- ------------------------------------------------------------
create or replace view v_stock_on_hand as
select sl.org_id, sl.item_id, i.item_code, i.name as item_name,
       sl.location_id, loc.name as location_name, loc.kind as location_kind,
       sum(sl.qty_base) as qty_base,
       sum(sl.qty_base) / nullif(i.units_per_box,0) as qty_boxes,
       i.reorder_level,
       (sum(sl.qty_base) <= i.reorder_level) as is_low,
       (sum(sl.qty_base) < 0)                as is_negative
from stock_ledger sl
join items i on i.id = sl.item_id
join stock_locations loc on loc.id = sl.location_id
group by sl.org_id, sl.item_id, i.item_code, i.name,
         sl.location_id, loc.name, loc.kind, i.units_per_box, i.reorder_level;

-- Mirrors the client's STOCK_REPORT: grouped by mestri section, in BOXES,
-- columns Item Code | Pack | Group / Item Name | Opening | Purchase | Sales | Closing
create or replace function closing_stock_report(
  p_org uuid, p_date date default current_date, p_location uuid default null
) returns table (
  section_code text, section_name text, sort_order integer,
  item_code text, pack text, item_name text,
  opening numeric, purchase numeric, sales numeric, closing numeric,
  is_negative boolean
) language sql stable as $$
  select sec.code, coalesce(sec.name,'OTHERS'), coalesce(sec.sort_order, 999),
         i.item_code, pt.code, i.name,
    coalesce(sum(sl.qty_base) filter (where sl.txn_date < p_date),0) / nullif(i.units_per_box,0),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date = p_date
             and sl.txn_type in ('purchase','production_in')),0) / nullif(i.units_per_box,0),
    coalesce(-sum(sl.qty_base) filter (where sl.txn_date = p_date
             and sl.txn_type = 'sale'),0) / nullif(i.units_per_box,0),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date),0) / nullif(i.units_per_box,0),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date),0) < 0
  from items i
  left join sections sec on sec.id = i.section_id
  left join pack_types pt on pt.id = i.pack_type_id
  left join stock_ledger sl on sl.item_id = i.id
       and (p_location is null or sl.location_id = p_location)
  where i.org_id = p_org and i.is_active and i.type = 'finished_good'
  group by sec.code, sec.name, sec.sort_order, i.id, i.item_code, pt.code, i.name, i.units_per_box
  order by coalesce(sec.sort_order,999), sec.name, i.name;
$$;

-- ------------------------------------------------------------
-- F. OUTSTANDING & THE RECEIPTS REGISTER
--    Modes are rows, so the register returns them as a map and the
--    UI renders one column per active mode. Adding a new head later
--    needs no code change.
-- ------------------------------------------------------------
create or replace view v_customer_outstanding as
with billed as (
  select customer_id, sum(total) amt from invoices
  where status <> 'cancelled' group by customer_id),
paid as (
  select customer_id, sum(total_amount) amt from receipts group by customer_id),
returned as (
  select customer_id, sum(total) amt from sales_returns group by customer_id)
select c.org_id, c.id as customer_id, c.code, c.name, c.town, c.route_id,
       c.opening_balance,
       coalesce(b.amt,0) as total_billed,
       coalesce(p.amt,0) as total_received,
       coalesce(r.amt,0) as total_returned,
       c.opening_balance + coalesce(b.amt,0) - coalesce(p.amt,0) - coalesce(r.amt,0)
         as outstanding
from customers c
left join billed b   on b.customer_id = c.id
left join paid   p   on p.customer_id = c.id
left join returned r on r.customer_id = c.id;

create or replace function receipts_register(
  p_org uuid, p_from date, p_to date, p_route uuid default null
) returns table (
  sno bigint, customer_id uuid, name text, town text,
  total_outstanding numeric,
  by_mode jsonb,              -- {"CASH":1200,"BSR":300,…} keyed by receipt_modes.code
  fresh_return numeric, rate_difference numeric, damage_return numeric,
  remaining_outstanding numeric
) language sql stable as $$
  with lines as (
    select rc.customer_id, m.code, sum(rl.amount) amt
    from receipts rc
    join receipt_lines rl on rl.receipt_id = rc.id
    join receipt_modes m  on m.id = rl.mode_id
    where rc.org_id = p_org and rc.receipt_date between p_from and p_to
    group by rc.customer_id, m.code
  ),
  r as (
    select customer_id, jsonb_object_agg(code, amt) by_mode, sum(amt) total
    from lines group by customer_id
  ),
  ret as (
    select customer_id,
      sum(total) filter (where kind='fresh_return')    fr,
      sum(total) filter (where kind='rate_difference') rd,
      sum(total) filter (where kind='damage_return')   dr,
      sum(total) total
    from sales_returns
    where org_id = p_org and return_date between p_from and p_to
    group by customer_id
  )
  select row_number() over (order by c.town, c.name),
         c.id, c.name, c.town, o.outstanding,
         coalesce(r.by_mode,'{}'::jsonb),
         coalesce(ret.fr,0), coalesce(ret.rd,0), coalesce(ret.dr,0),
         o.outstanding - coalesce(r.total,0) - coalesce(ret.total,0)
  from customers c
  join v_customer_outstanding o on o.customer_id = c.id
  left join r   on r.customer_id = c.id
  left join ret on ret.customer_id = c.id
  where c.org_id = p_org and (p_route is null or c.route_id = p_route)
  order by c.town, c.name;
$$;

-- ------------------------------------------------------------
-- G. PRODUCTION
-- ------------------------------------------------------------
create or replace function open_production_batch(
  p_org uuid, p_item uuid, p_plates numeric,
  p_date date default current_date, p_chief uuid default null
) returns uuid language plpgsql as $$
declare v_batch uuid; v_recipe recipes%rowtype; it items%rowtype; v_pieces numeric;
begin
  select * into it from items where id = p_item;
  select * into v_recipe from recipes
    where item_id = p_item and is_active order by created_at desc limit 1;

  v_pieces := coalesce(v_recipe.pieces_per_plate,0) * p_plates;

  insert into production_batches (
    org_id, batch_no, item_id, recipe_id, production_date, no_of_plates,
    expected_pieces, expected_jars, expected_boxes, chief_id)
  values (
    p_org, next_doc_no(p_org,'batch'), p_item, v_recipe.id, p_date, p_plates,
    v_pieces,
    v_pieces / nullif(it.pieces_per_unit,0),
    v_pieces / nullif(it.pieces_per_unit * it.units_per_box,0),
    p_chief)
  returning id into v_batch;

  insert into batch_ingredients (
    batch_id, ingredient_id, qty_per_plate, no_of_plates, expected_qty, uom_id, rate)
  select v_batch, ri.ingredient_id, ri.qty_per_plate, p_plates,
         ri.qty_per_plate * p_plates, ri.uom_id,
         coalesce((select purchase_rate from items where id = ri.ingredient_id),0)
  from recipe_ingredients ri where ri.recipe_id = v_recipe.id;

  return v_batch;
end $$;

create or replace function close_production_batch(p_batch uuid)
returns void language plpgsql as $$
declare b production_batches%rowtype; it items%rowtype; v_qty numeric;
begin
  select * into b from production_batches where id = p_batch;
  select * into it from items where id = b.item_id;

  update batch_ingredients set amount = actual_qty * rate where batch_id = p_batch;
  delete from stock_ledger where ref_table='production_batches' and ref_id=p_batch;

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id)
  select b.org_id, bi.ingredient_id, b.location_id, 'production_consume', b.production_date,
         -to_base_qty(bi.ingredient_id, bi.actual_qty, bi.uom_id), bi.rate,
         'production_batches', b.id
  from batch_ingredients bi where bi.batch_id = p_batch;

  v_qty := pieces_to_uom(b.item_id, b.actual_pieces, it.base_uom_id);

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,ref_table,ref_id)
  values (b.org_id, b.item_id, b.location_id, 'production_in', b.production_date,
          v_qty, 'production_batches', b.id);

  update production_batches set status='closed' where id = p_batch;
end $$;

create or replace view v_production_sheet as
select pb.org_id, pb.id as batch_id, pb.production_date,
       i.name as item_name, sec.name as section_name,
       ing.name as ingredient,
       bi.qty_per_plate as quantity,
       bi.no_of_plates,
       bi.expected_qty as total_usage_per_plate,
       bi.actual_qty   as total_used_by_chief,
       bi.difference,
       pb.no_of_workers, pb.mestry_count as mestry, pb.labour_count as labour,
       pb.expected_boxes, pb.actual_boxes,
       (pb.actual_boxes - pb.expected_boxes) as box_difference
from production_batches pb
join items i on i.id = pb.item_id
left join sections sec on sec.id = i.section_id
join batch_ingredients bi on bi.batch_id = pb.id
join items ing on ing.id = bi.ingredient_id;

-- ------------------------------------------------------------
-- H. PACKING LOCK — units_per_box freezes once stock has moved
-- ------------------------------------------------------------
create or replace function trg_lock_packing() returns trigger language plpgsql as $$
begin
  if new.units_per_box is distinct from old.units_per_box
     and exists (select 1 from stock_ledger where item_id = old.id) then
    raise exception
      'Packing is locked: % already has stock movement. Create a new item code for a repack.',
      old.item_code;
  end if;
  return new;
end $$;

create trigger t_lock_packing before update on items
  for each row execute function trg_lock_packing();

-- ------------------------------------------------------------
-- I. DASHBOARD
-- ------------------------------------------------------------
create or replace function dashboard_summary(p_org uuid, p_date date default current_date)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'sales_today',      (select coalesce(sum(total),0) from invoices
                          where org_id=p_org and invoice_date=p_date and status<>'cancelled'),
    'sales_mtd',        (select coalesce(sum(total),0) from invoices
                          where org_id=p_org and status<>'cancelled'
                            and invoice_date >= date_trunc('month',p_date)),
    'collection_today', (select coalesce(sum(total_amount),0) from receipts
                          where org_id=p_org and receipt_date=p_date),
    'total_outstanding',(select coalesce(sum(outstanding),0) from v_customer_outstanding
                          where org_id=p_org),
    'invoices_today',   (select count(*) from invoices where org_id=p_org and invoice_date=p_date),
    'low_stock_items',  (select count(*) from v_stock_on_hand where org_id=p_org and is_low),
    'negative_stock',   (select count(*) from v_stock_on_hand where org_id=p_org and is_negative),
    'vehicles_out',     (select count(*) from vehicle_trips
                          where org_id=p_org and trip_date=p_date and status='dispatched'),
    'batches_open',     (select count(*) from production_batches
                          where org_id=p_org and status='open'),
    'pending_orders',   (select count(*) from inbound_orders where org_id=p_org and status='new')
  );
$$;
