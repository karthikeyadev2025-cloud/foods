-- ============================================================
-- JYOTHI FOODS ERP — 29: A UNIT THAT WEIGHS NOTHING
--
-- Saving a quotation died with:
--
--     23502  null value in column "qty_base" of relation "quotation_items"
--
-- which tells the person standing at the billing screen nothing they can act
-- on. Reproduced exactly, and the cause is one empty box in Setup:
--
--     a unit whose basis is 'weight' with its grams left blank,
--     set as the stock unit of an item that has a net weight.
--
-- pieces_to_uom then divides by nullif(u.weight_g, 0) and hands back NULL.
-- The NULL travels untouched through doc_line and save_quotation until it
-- meets a NOT NULL constraint three tables away, where nothing can name the
-- item, the unit, or the box to go and fill in.
--
-- The other two divisors in those helpers cannot be zero — items carries
-- CHECK (units_per_box > 0) and CHECK (pieces_per_unit > 0) — but `uoms` has
-- no constraints at all, and Setup > Units accepts a weight unit with zero
-- grams. So this is the only way in, and it is wide open.
--
-- The same expression hides a second, quieter bug going the other way:
--
--     (p_qty * coalesce(u.weight_g, 1)) / it.net_weight_g
--
-- An unset kilogram is read as ONE GRAM, and the quantity comes out a
-- thousandfold wrong — on a bill, in the stock ledger, with nothing on screen
-- to show for it. A wrong number that looks right is worse than a refusal, so
-- that coalesce goes too.
--
-- Neither is a conversion the database may guess: only the shop knows whether
-- their unit means a kilogram or half of one. So both helpers now raise and
-- name the box to fill.
--
-- Fixed in the shared helpers rather than in save_quotation because that is
-- where the NULL is born. The same NULL reaches quotations, orders, challans,
-- purchase returns, the stock-ledger trigger and production close — all six
-- through these two functions.
--
-- FORWARD ONLY. These live in 02_logic.sql; do not go back and edit that, and
-- never run a lower-numbered file after this one. Postgres keeps whichever
-- `create or replace` ran last.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Entered quantity -> pieces
-- ------------------------------------------------------------
create or replace function qty_to_pieces(p_item uuid, p_qty numeric, p_uom uuid)
returns numeric language plpgsql stable as $$
declare it items%rowtype; u uoms%rowtype;
begin
  select * into it from items where id = p_item;
  if not found then raise exception 'Item % not found', p_item; end if;

  if p_uom is null then
    -- Reached whenever an item never got a stock unit, which is worth saying
    -- plainly instead of "UOM <null> not found".
    raise exception 'Item "%" has no stock unit set. Open Items, choose it, and set "Stock kept in".', it.name
      using errcode = '23514', hint = 'Setup > Units lists the units you can pick.';
  end if;
  select * into u from uoms where id = p_uom;
  if not found then raise exception 'UOM % not found', p_uom; end if;

  if u.basis = 'weight' and coalesce(it.net_weight_g, 0) > 0 and coalesce(u.weight_g, 0) <= 0 then
    raise exception 'Unit "%" has no weight set, so "%" cannot be measured in it. Open Setup > Units and put in its weight in grams — 1000 for a kilogram, 1 for a gram.', u.code, it.name
      using errcode = '23514';
  end if;

  return case u.basis
    when 'box'    then p_qty * it.units_per_box * it.pieces_per_unit
    when 'unit'   then p_qty * it.pieces_per_unit
    when 'piece'  then p_qty
    when 'weight' then case
                         when coalesce(it.net_weight_g,0) > 0
                         then (p_qty * u.weight_g) / it.net_weight_g
                         else p_qty * coalesce(u.weight_g,1) / 1000
                       end
  end;
end $$;

-- ------------------------------------------------------------
-- 2. Pieces -> some uom. This is the one that returned NULL.
-- ------------------------------------------------------------
create or replace function pieces_to_uom(p_item uuid, p_pieces numeric, p_uom uuid)
returns numeric language plpgsql stable as $$
declare it items%rowtype; u uoms%rowtype; v_div numeric;
begin
  select * into it from items where id = p_item;
  if not found then raise exception 'Item % not found', p_item; end if;

  if p_uom is null then
    raise exception 'Item "%" has no stock unit set. Open Items, choose it, and set "Stock kept in".', it.name
      using errcode = '23514', hint = 'Setup > Units lists the units you can pick.';
  end if;
  select * into u from uoms where id = p_uom;
  if not found then raise exception 'UOM % not found', p_uom; end if;

  if u.basis = 'piece' then return p_pieces; end if;

  if u.basis = 'weight' then
    if coalesce(it.net_weight_g, 0) <= 0 then return p_pieces; end if;
    if coalesce(u.weight_g, 0) <= 0 then
      raise exception 'Unit "%" has no weight set, so "%" cannot be measured in it. Open Setup > Units and put in its weight in grams — 1000 for a kilogram, 1 for a gram.', u.code, it.name
        using errcode = '23514';
    end if;
    return (p_pieces * it.net_weight_g) / u.weight_g;
  end if;

  -- box and unit. Both divisors are held above zero by a CHECK on items, so
  -- this guard should never fire — but it is the divisor, and a NULL escaping
  -- here is exactly the bug this file exists to close.
  v_div := case u.basis when 'box' then it.units_per_box * it.pieces_per_unit else it.pieces_per_unit end;
  if coalesce(v_div, 0) <= 0 then
    raise exception 'Item "%" cannot be measured in "%": units per box and pieces per unit must both be more than zero. Open Items > "%".', it.name, u.code, it.name
      using errcode = '23514';
  end if;
  return p_pieces / v_div;
end $$;

-- ------------------------------------------------------------
-- 3. Find them all, instead of one failed save at a time
-- ------------------------------------------------------------
/**
 * The billing screen now names the item it choked on, but that is one item per
 * attempt, and a shop that sells by weight will have a whole section of them.
 * This lists every active item that would fail, with the box to fill, so the
 * master can be put right in one sitting.
 */
create or replace function items_needing_measure()
returns table (item_code text, name text, section_name text, problem text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_view('items') then raise exception 'Items are not available to your role'; end if;
  return query
    select i.item_code, i.name, s.name,
           case
             when i.base_uom_id is null then 'No stock unit — open the item and set "Stock kept in"'
             else format('Unit "%s" has no weight — open Setup > Units and set its grams', u.code)
           end
      from items i
      left join uoms u on u.id = i.base_uom_id
      left join sections s on s.id = i.section_id
     where i.org_id = my_org_id() and i.is_active
       and (i.base_uom_id is null
            or (u.basis = 'weight' and coalesce(i.net_weight_g, 0) > 0 and coalesce(u.weight_g, 0) <= 0))
     order by s.sort_order nulls last, i.name;
end $$;
