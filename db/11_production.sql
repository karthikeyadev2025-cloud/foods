-- ============================================================
-- JYOTHI FOODS ERP — 11: PRODUCTION (T4)
-- Recipe per item (qty per plate, pieces per plate). Morning: open a
-- batch with a plate count → expected usage and expected boxes ride
-- entirely on the master. Evening: the chief enters actual usage and
-- actual boxes. Close: raw material consumed, finished goods added,
-- batch costed. The chief only ever sees today's open batch.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Recipes
-- ------------------------------------------------------------
create or replace view v_recipe_list as
select r.id, r.org_id, r.item_id, i.item_code, i.name as item_name, i.units_per_box, i.pieces_per_unit,
       s.name as section_name, s.mestri_id, m.full_name as mestri_name,
       r.name, r.pieces_per_plate, r.is_active, r.created_at,
       coalesce((select count(*) from recipe_ingredients ri where ri.recipe_id = r.id), 0) as ingredient_count,
       round(r.pieces_per_plate / nullif(i.pieces_per_unit * i.units_per_box, 0), 3) as boxes_per_plate,
       coalesce((select sum(ri.qty_per_plate * coalesce(ing.purchase_rate, 0))
                   from recipe_ingredients ri join items ing on ing.id = ri.ingredient_id where ri.recipe_id = r.id), 0) as cost_per_plate
from recipes r
join items i on i.id = r.item_id
left join sections s on s.id = i.section_id
left join staff m on m.id = s.mestri_id;
alter view v_recipe_list set (security_invoker = on);

create or replace view v_recipe_ingredients as
select ri.id, ri.recipe_id, ri.ingredient_id, ing.item_code, ing.name as ingredient_name, ri.qty_per_plate,
       ri.uom_id, u.code as uom_code, ing.purchase_rate as rate
from recipe_ingredients ri
join items ing on ing.id = ri.ingredient_id
left join uoms u on u.id = ri.uom_id;
alter view v_recipe_ingredients set (security_invoker = on);

-- p_header: {id?, item_id, name?, pieces_per_plate, is_active?}
-- p_ingredients: [{ingredient_id, qty_per_plate, uom_id}]
create or replace function save_recipe(p_header jsonb, p_ingredients jsonb)
returns uuid language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p_header->>'id','')::uuid; it items%rowtype; l jsonb; n int := 0; ing items%rowtype;
begin
  if my_role() = 'chief' then raise exception 'Chiefs enter actuals; recipes are set by the production head'; end if;
  select * into it from items where id = (p_header->>'item_id')::uuid and org_id = v_org;
  if not found then raise exception 'Item not found'; end if;
  if it.type <> 'finished_good' then raise exception '% is not a finished good', it.item_code; end if;
  if coalesce((p_header->>'pieces_per_plate')::numeric, 0) <= 0 then raise exception 'Pieces per plate must be greater than zero'; end if;
  if jsonb_typeof(p_ingredients) <> 'array' or jsonb_array_length(p_ingredients) = 0 then raise exception 'A recipe needs at least one ingredient'; end if;

  if v_id is null then
    -- one active recipe per item: retire the previous one
    update recipes set is_active = false where org_id = v_org and item_id = it.id and is_active;
    insert into recipes (org_id, item_id, name, pieces_per_plate, is_active)
    values (v_org, it.id, coalesce(nullif(p_header->>'name',''), it.name), (p_header->>'pieces_per_plate')::numeric, true)
    returning id into v_id;
  else
    update recipes set name = coalesce(nullif(p_header->>'name',''), name),
                       pieces_per_plate = (p_header->>'pieces_per_plate')::numeric,
                       is_active = coalesce((p_header->>'is_active')::boolean, is_active)
    where id = v_id and org_id = v_org;
    if not found then raise exception 'Recipe not found'; end if;
    delete from recipe_ingredients where recipe_id = v_id;
  end if;

  for l in select * from jsonb_array_elements(p_ingredients) loop
    n := n + 1;
    select * into ing from items where id = (l->>'ingredient_id')::uuid and org_id = v_org;
    if not found then raise exception 'Ingredient %: item not found', n; end if;
    if ing.type = 'finished_good' then raise exception 'Ingredient %: % is a finished good', n, ing.item_code; end if;
    if coalesce((l->>'qty_per_plate')::numeric, 0) <= 0 then raise exception 'Ingredient % (%): quantity per plate must be > 0', n, ing.item_code; end if;
    insert into recipe_ingredients (recipe_id, ingredient_id, qty_per_plate, uom_id)
    values (v_id, ing.id, (l->>'qty_per_plate')::numeric, coalesce(nullif(l->>'uom_id','')::uuid, ing.base_uom_id));
  end loop;
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 2. Batches
-- ------------------------------------------------------------
alter table production_batches add column if not exists ingredient_cost numeric(14,2) not null default 0;
alter table production_batches add column if not exists total_cost numeric(14,2) not null default 0;
alter table production_batches add column if not exists closed_at timestamptz;

create or replace view v_batch_list as
select b.id, b.org_id, b.batch_no, b.production_date, b.status, b.item_id, i.item_code, i.name as item_name,
       i.units_per_box, i.pieces_per_unit, s.name as section_name, m.full_name as mestri_name,
       b.recipe_id, b.no_of_plates, b.expected_pieces, b.expected_jars, b.expected_boxes,
       b.actual_pieces, b.actual_jars, b.actual_boxes,
       (b.actual_boxes - b.expected_boxes) as box_difference,
       b.no_of_workers, b.mestry_count, b.labour_count, b.labour_cost, b.ingredient_cost, b.total_cost,
       b.chief_id, c.full_name as chief_name, b.location_id, l.name as location_name, b.notes, b.created_at, b.closed_at,
       case when b.actual_boxes > 0 then round(b.total_cost / b.actual_boxes, 2) else null end as cost_per_box
from production_batches b
join items i on i.id = b.item_id
left join sections s on s.id = i.section_id
left join staff m on m.id = s.mestri_id
left join staff c on c.id = b.chief_id
left join stock_locations l on l.id = b.location_id;
alter view v_batch_list set (security_invoker = on);

-- The production sheet: one row per ingredient, the client's columns.
create or replace view v_batch_ingredients as
select bi.id, bi.batch_id, bi.ingredient_id, ing.item_code, ing.name as ingredient,
       bi.qty_per_plate as quantity, bi.no_of_plates, bi.expected_qty as total_usage_per_plate,
       bi.actual_qty as total_used_by_chief, bi.difference, bi.rate, bi.amount,
       bi.uom_id, u.code as uom_code
from batch_ingredients bi
join items ing on ing.id = bi.ingredient_id
left join uoms u on u.id = bi.uom_id;
alter view v_batch_ingredients set (security_invoker = on);

-- Morning. p: {item_id, plates, production_date?, chief_id?, location_id, no_of_workers?, mestry_count?, labour_count?, notes?}
drop function if exists open_production_batch(uuid, uuid, numeric, date, uuid);
create or replace function open_production_batch(p jsonb)
returns uuid language plpgsql as $$
declare v_org uuid := my_org_id(); v_batch uuid; rc recipes%rowtype; it items%rowtype; v_plates numeric; v_pieces numeric; v_loc uuid;
begin
  if my_role() = 'chief' then raise exception 'Chiefs enter actuals; the production head opens batches'; end if;
  select * into it from items where id = (p->>'item_id')::uuid and org_id = v_org;
  if not found then raise exception 'Item not found'; end if;
  select * into rc from recipes where org_id = v_org and item_id = it.id and is_active order by created_at desc limit 1;
  if not found then raise exception '% has no active recipe — add one under Production → Recipes', it.item_code; end if;
  v_plates := coalesce((p->>'plates')::numeric, 0);
  if v_plates <= 0 then raise exception 'Number of plates must be greater than zero'; end if;
  v_loc := nullif(p->>'location_id','')::uuid;
  if v_loc is null or not exists (select 1 from stock_locations where id = v_loc and org_id = v_org) then
    raise exception 'Choose the location raw material is drawn from and finished goods go to';
  end if;

  v_pieces := rc.pieces_per_plate * v_plates;
  insert into production_batches (org_id, batch_no, item_id, recipe_id, production_date, no_of_plates,
                                  expected_pieces, expected_jars, expected_boxes,
                                  no_of_workers, mestry_count, labour_count, chief_id, location_id, notes, created_by)
  values (v_org, next_doc_no(v_org, 'batch'), it.id, rc.id,
          coalesce(nullif(p->>'production_date','')::date, current_date), v_plates,
          v_pieces,
          round(v_pieces / nullif(it.pieces_per_unit, 0), 3),
          round(v_pieces / nullif(it.pieces_per_unit * it.units_per_box, 0), 3),
          coalesce((p->>'no_of_workers')::int, 0), coalesce((p->>'mestry_count')::int, 0), coalesce((p->>'labour_count')::int, 0),
          nullif(p->>'chief_id','')::uuid, v_loc, nullif(p->>'notes',''), my_staff_id())
  returning id into v_batch;

  -- explode the recipe: expected usage per ingredient at the current purchase rate
  insert into batch_ingredients (batch_id, ingredient_id, qty_per_plate, no_of_plates, expected_qty, uom_id, rate)
  select v_batch, ri.ingredient_id, ri.qty_per_plate, v_plates, round(ri.qty_per_plate * v_plates, 4), ri.uom_id,
         coalesce((select purchase_rate from items where id = ri.ingredient_id), 0)
  from recipe_ingredients ri where ri.recipe_id = rc.id;
  return v_batch;
end $$;

-- Evening. The chief (or head) enters what was actually used and produced.
-- p: {actual_boxes?, no_of_workers?, mestry_count?, labour_count?, labour_cost?, notes?, lines: [{id, actual_qty}]}
create or replace function update_batch_actuals(p_batch uuid, p jsonb)
returns void language plpgsql as $$
declare b production_batches%rowtype; it items%rowtype; l jsonb; v_boxes numeric;
begin
  select * into b from production_batches where id = p_batch and org_id = my_org_id() for update;
  if not found then raise exception 'Batch not found'; end if;
  if b.status <> 'open' then raise exception 'Batch % is %; actuals are frozen', b.batch_no, b.status; end if;
  select * into it from items where id = b.item_id;

  if p ? 'actual_boxes' then
    v_boxes := coalesce((p->>'actual_boxes')::numeric, 0);
    if v_boxes < 0 then raise exception 'Actual boxes cannot be negative'; end if;
    update production_batches set
      actual_boxes  = v_boxes,
      actual_jars   = round(v_boxes * it.units_per_box, 3),
      actual_pieces = round(v_boxes * it.units_per_box * it.pieces_per_unit, 3)
    where id = p_batch;
  end if;
  update production_batches set
    no_of_workers = coalesce((p->>'no_of_workers')::int, no_of_workers),
    mestry_count  = coalesce((p->>'mestry_count')::int, mestry_count),
    labour_count  = coalesce((p->>'labour_count')::int, labour_count),
    labour_cost   = coalesce((p->>'labour_cost')::numeric, labour_cost),
    notes         = coalesce(nullif(p->>'notes',''), notes)
  where id = p_batch;

  if jsonb_typeof(p->'lines') = 'array' then
    for l in select * from jsonb_array_elements(p->'lines') loop
      update batch_ingredients set actual_qty = coalesce((l->>'actual_qty')::numeric, actual_qty)
      where id = (l->>'id')::uuid and batch_id = p_batch;
    end loop;
  end if;
end $$;

-- Close: consume, add, cost. Replaces the 05 version to add costing and the role guard.
create or replace function close_production_batch(p_batch uuid)
returns void language plpgsql as $$
declare b production_batches%rowtype; it items%rowtype; v_qty numeric; v_ing numeric;
begin
  if my_role() = 'chief' then raise exception 'Chiefs enter actuals; the production head closes the batch'; end if;
  select * into b from production_batches where id = p_batch and org_id = my_org_id() for update;
  if not found then raise exception 'Batch not found'; end if;
  if b.status <> 'open' then raise exception 'Batch % is already %', b.batch_no, b.status; end if;
  if b.location_id is null then raise exception 'Batch % has no stock location', b.batch_no; end if;
  if b.actual_boxes <= 0 then raise exception 'Enter the actual boxes produced before closing'; end if;
  select * into it from items where id = b.item_id;

  update batch_ingredients set amount = round(actual_qty * rate, 2) where batch_id = p_batch;
  select coalesce(sum(amount), 0) into v_ing from batch_ingredients where batch_id = p_batch;

  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
  select b.org_id, bi.ingredient_id, b.location_id, 'production_consume', b.production_date,
         -to_base_qty(bi.ingredient_id, bi.actual_qty, bi.uom_id), bi.rate, 'production_batches', b.id, my_staff_id()
  from batch_ingredients bi where bi.batch_id = p_batch and bi.actual_qty <> 0;

  v_qty := pieces_to_uom(b.item_id, b.actual_pieces, it.base_uom_id);
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
  values (b.org_id, b.item_id, b.location_id, 'production_in', b.production_date, v_qty,
          case when v_qty > 0 then round((v_ing + b.labour_cost) / v_qty, 2) else 0 end,
          'production_batches', b.id, my_staff_id());

  -- Costing is memo: raw material was expensed on purchase and wages on
  -- payment, so closing a batch moves no money and posts no journal entry.
  update production_batches
     set status = 'closed', ingredient_cost = v_ing, total_cost = round(v_ing + labour_cost, 2), closed_at = now()
   where id = p_batch;
end $$;

create or replace function cancel_production_batch(p_batch uuid)
returns void language plpgsql as $$
declare b production_batches%rowtype;
begin
  if my_role() = 'chief' then raise exception 'Only the production head can cancel a batch'; end if;
  select * into b from production_batches where id = p_batch and org_id = my_org_id() for update;
  if not found then raise exception 'Batch not found'; end if;
  if b.status <> 'open' then raise exception 'Batch % is %; only open batches can be cancelled', b.batch_no, b.status; end if;
  update production_batches set status = 'cancelled' where id = p_batch;
end $$;

-- ------------------------------------------------------------
-- 3. The chief sees only today's open batch (RLS, not the UI).
-- ------------------------------------------------------------
drop policy if exists org_read on production_batches;
create policy org_read on production_batches for select
  using (org_id = my_org_id() and can_view('production')
         and (my_role() <> 'chief' or (status = 'open' and production_date = current_date)));

-- ------------------------------------------------------------
-- 4. Variance: expected vs actual, by item, by mestri, by week.
-- ------------------------------------------------------------
create or replace function production_variance(p_org uuid, p_from date, p_to date, p_group text default 'item')
returns table (
  group_key text, group_label text, batches bigint, plates numeric,
  expected_boxes numeric, actual_boxes numeric, box_variance numeric, box_variance_pct numeric,
  expected_ingredient_cost numeric, actual_ingredient_cost numeric, ingredient_variance numeric,
  labour_cost numeric, total_cost numeric, cost_per_box numeric
) language sql stable as $$
  with b as (
    select pb.*, i.item_code, i.name as item_name, s.name as section_name, coalesce(m.full_name, s.name, '—') as mestri_name,
           to_char(date_trunc('week', pb.production_date), 'IYYY-"W"IW') as week_key,
           'Week of ' || to_char(date_trunc('week', pb.production_date), 'DD-MM-YYYY') as week_label,
           (select coalesce(sum(expected_qty * rate), 0) from batch_ingredients bi where bi.batch_id = pb.id) as exp_cost,
           (select coalesce(sum(actual_qty * rate), 0)   from batch_ingredients bi where bi.batch_id = pb.id) as act_cost
    from production_batches pb
    join items i on i.id = pb.item_id
    left join sections s on s.id = i.section_id
    left join staff m on m.id = s.mestri_id
    where pb.org_id = p_org and pb.status = 'closed'
      and pb.production_date between p_from and p_to
  )
  select
    case p_group when 'mestri' then mestri_name when 'week' then week_key else item_code end,
    case p_group when 'mestri' then mestri_name when 'week' then week_label else item_code || ' — ' || item_name end,
    count(*), sum(no_of_plates),
    sum(expected_boxes), sum(actual_boxes), sum(actual_boxes) - sum(expected_boxes),
    case when sum(expected_boxes) > 0 then round((sum(actual_boxes) - sum(expected_boxes)) * 100 / sum(expected_boxes), 2) else null end,
    round(sum(exp_cost), 2), round(sum(act_cost), 2), round(sum(act_cost) - sum(exp_cost), 2),
    sum(labour_cost), sum(total_cost),
    case when sum(actual_boxes) > 0 then round(sum(total_cost) / sum(actual_boxes), 2) else null end
  from b
  group by 1, 2
  order by 1;
$$;
