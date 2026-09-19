-- ============================================================
-- JYOTHI FOODS ERP — 51: THE STOCK REPORT'S "PURCHASE" COLUMN WAS NOT PURCHASES
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- Found while checking the 4.25 on 1/- KALAJAM(12). The purchase really was
-- 2.25 boxes. The report said 4.25, and the report was adding up something
-- other than what its heading claimed:
--
--   opening   everything before today                      — correct
--   purchase  EVERY POSITIVE MOVEMENT today                — labelled "Purchase"
--   sales     EVERY NEGATIVE MOVEMENT today                — labelled "Sales"
--   closing   everything up to and including today         — correct
--
-- A bill had been raised for 2 boxes and then cancelled. Cancelling puts the
-- goods back, which is a positive movement, so the 2 boxes landed in the column
-- headed Purchase: 2.25 bought + 2 returned = 4.25. The closing figure was
-- right all along; both middle columns were overstated by the same 2.
--
-- That is worse than a cosmetic fault. A shopkeeper reading "Purchase 4.25"
-- believes he bought four and a quarter boxes, and will say so to the supplier.
--
-- Now each column means what it says, and the four still add up:
--
--   opening + purchase + production − sales + other = closing
--
-- "other" is the net of everything that is neither a purchase nor a sale —
-- returns, godown transfers, count adjustments, van movements, and the goods a
-- cancelled bill puts back. One signed column rather than two, because what the
-- shop needs to see is that the balance still reconciles.
--
-- The signature changes, so the function is DROPPED first: `create or replace`
-- cannot add a column to a returns-table function and fails with "cannot change
-- return type of existing function".
-- ============================================================

drop function if exists closing_stock_report(uuid, date, uuid, uuid);

create or replace function closing_stock_report(
  p_org uuid, p_date date default current_date, p_location uuid default null, p_section uuid default null
) returns table (
  section_id uuid, section_code text, section_name text, sort_order integer,
  item_id uuid, item_code text, pack text, item_name text, units_per_box integer,
  opening numeric, purchase numeric, production numeric, sales numeric, other numeric, closing numeric,
  opening_units numeric, closing_units numeric, is_negative boolean
) language sql stable as $$
  select sec.id, sec.code, coalesce(sec.name, 'OTHERS'), coalesce(sec.sort_order, 999),
         i.id, i.item_code, pt.code, i.name, i.units_per_box,
    -- opening: everything before today
    round(coalesce(sum(sl.qty_base) filter (where sl.txn_date < p_date), 0) / nullif(i.units_per_box, 0), 3),
    -- purchase: goods bought in, and nothing else
    round(coalesce(sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type = 'purchase'), 0) / nullif(i.units_per_box, 0), 3),
    -- production: what the kitchen made today
    round(coalesce(sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type = 'production_in'), 0) / nullif(i.units_per_box, 0), 3),
    -- sales: goods sold, shown positive. A cancelled bill's rows net to nothing
    -- here rather than inflating this column and "other" separately.
    round(coalesce(-sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type = 'sale'), 0) / nullif(i.units_per_box, 0), 3),
    -- other: the net of everything else — returns, transfers, adjustments, van
    -- movements. Signed, so the row still adds up left to right.
    round(coalesce(sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type not in ('purchase', 'production_in', 'sale')), 0)
          / nullif(i.units_per_box, 0), 3),
    -- closing: everything up to and including today
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
