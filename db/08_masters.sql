-- ============================================================
-- JYOTHI FOODS ERP — 08: MASTERS (T1)
-- Items, customers, sections, vehicles: what the screens need
-- beyond the raw tables, plus the last places an "8" could hide.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Packing is typed on Add Product, never assumed. The schema
--    default of 8 was the one place rule 2 could still leak.
-- ------------------------------------------------------------
alter table items alter column units_per_box drop default;
alter table items drop constraint if exists items_units_per_box_positive;
alter table items add constraint items_units_per_box_positive check (units_per_box > 0);
alter table items drop constraint if exists items_pieces_per_unit_positive;
alter table items add constraint items_pieces_per_unit_positive check (pieces_per_unit > 0);

-- ------------------------------------------------------------
-- 2. Item list: one row per item with everything the list and the
--    edit screen need, including whether packing is locked.
-- ------------------------------------------------------------
create or replace view v_item_list as
select i.id, i.org_id, i.item_code, i.name, i.type, i.is_active, i.created_at,
       i.pack_type_id, pt.code as pack_code,
       i.section_id, s.code as section_code, s.name as section_name, coalesce(s.sort_order, 999) as section_sort,
       i.base_uom_id, u.code as base_uom_code,
       i.units_per_box, i.pieces_per_unit, i.mrp_per_piece, i.net_weight_g,
       i.unit_rate, i.box_rate, i.purchase_rate, i.reorder_level, i.shelf_life_days,
       exists (select 1 from stock_ledger sl where sl.item_id = i.id) as has_stock_movement,
       coalesce((select sum(sl.qty_base) from stock_ledger sl where sl.item_id = i.id), 0) as stock_base
from items i
left join pack_types pt on pt.id = i.pack_type_id
left join sections s on s.id = i.section_id
left join uoms u on u.id = i.base_uom_id;

alter view v_item_list set (security_invoker = on);

-- ------------------------------------------------------------
-- 3. Customer list with route name and live outstanding.
-- ------------------------------------------------------------
create or replace view v_customer_list as
select c.id, c.org_id, c.code, c.name, c.mobile1, c.mobile2, c.mobile3, c.town, c.address,
       c.route_id, r.name as route_name, c.price_group, c.credit_limit, c.opening_balance,
       c.whatsapp_opt_in, c.is_active, c.created_at, c.price_list_id,
       coalesce(o.outstanding, 0) as outstanding
from customers c
left join routes r on r.id = c.route_id
left join v_customer_outstanding o on o.customer_id = c.id;

alter view v_customer_list set (security_invoker = on);

-- Duplicate check on mobile1 is a constraint, not a hope.
create unique index if not exists customers_org_mobile1_uniq
  on customers (org_id, mobile1) where mobile1 is not null;

-- ------------------------------------------------------------
-- 4. Sections: reorder in one call (drag-to-reorder on screen).
-- ------------------------------------------------------------
create or replace function reorder_sections(p_ids uuid[])
returns void language plpgsql as $$
declare v_org uuid := my_org_id(); n int;
begin
  select count(*) into n from sections where org_id = v_org and id = any(p_ids);
  if n <> array_length(p_ids, 1) then
    raise exception 'reorder_sections: every id must be a section of your organisation';
  end if;
  update sections s set sort_order = x.ord
    from unnest(p_ids) with ordinality as x(id, ord)
   where s.id = x.id and s.org_id = v_org;
end $$;

-- ------------------------------------------------------------
-- 5. A vehicle is a stock location. Creating one creates its
--    location; renaming it renames the location. Definer rights so
--    a store keeper (edit on vehicles, not on setup) can do it.
-- ------------------------------------------------------------
create or replace function trg_vehicle_location() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.org_id is distinct from my_org_id() then
    raise exception 'Cannot create a vehicle for another organisation';
  end if;
  if tg_op = 'INSERT' then
    if new.location_id is null then
      insert into stock_locations (org_id, name, kind)
      values (new.org_id, 'VAN ' || upper(trim(new.vehicle_number)), 'vehicle')
      returning id into new.location_id;
    end if;
  elsif new.vehicle_number is distinct from old.vehicle_number and new.location_id is not null then
    update stock_locations set name = 'VAN ' || upper(trim(new.vehicle_number)) where id = new.location_id;
  end if;
  if new.is_active is distinct from old.is_active and new.location_id is not null then
    update stock_locations set is_active = new.is_active where id = new.location_id;
  end if;
  return new;
end $$;

drop trigger if exists t_vehicle_location on vehicles;
create trigger t_vehicle_location before insert or update on vehicles
  for each row execute function trg_vehicle_location();

-- Vehicle list with driver, route and location names.
create or replace view v_vehicle_list as
select v.id, v.org_id, v.vehicle_number, v.owner_name, v.capacity_boxes, v.is_active, v.created_at,
       v.driver_id, d.full_name as driver_name,
       v.route_id, r.name as route_name,
       v.location_id, l.name as location_name
from vehicles v
left join staff d on d.id = v.driver_id
left join routes r on r.id = v.route_id
left join stock_locations l on l.id = v.location_id;

alter view v_vehicle_list set (security_invoker = on);
