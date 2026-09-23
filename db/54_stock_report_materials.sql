-- ============================================================
-- JYOTHI FOODS ERP — 54: THE STOCK REPORT HID EVERY RAW MATERIAL
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "i want purchase has to shown in opening stock — lot of wrong opening stock,
-- not according to purchases."
--
-- The report had this line in it, and has had since the first build:
--
--     where i.org_id = p_org and i.is_active and i.type = 'finished_good'
--
-- So SUGAR, PALM OIL, oil, flour, packing — everything the shop BUYS rather
-- than makes — was missing from the stock report entirely. Purchase bills for
-- them saved correctly, posted to stock correctly and reached the ledger
-- correctly. They simply had nowhere to appear. Enter a hundred bills for sugar
-- and the report looks exactly as it did before.
--
-- That reads as "the opening stock is wrong", because from the counter there is
-- no difference between a figure that is wrong and a figure that is absent.
--
-- The filter was not careless: the report reproduces STOCK_REPORT.xlsx, which
-- is a finished-goods sheet grouped by mestri section. But the shop has since
-- started entering what it buys, and a stock report that cannot show the stock
-- of a bought item is not a stock report. It was also inconsistent with the
-- rest of the system: v_item_stock behind Low stock has always counted every
-- type, which is why SUGAR could read -180.5 on one screen and not exist on
-- another.
--
-- WHAT CHANGES
--   1. Every item type is on the report. Raw and packing materials group under
--      headings of their own, after the mestri sections, so they are together
--      and the sections the shop knows are untouched.
--   2. A new item_type column, so the screen can show one kind at a time
--      without another round trip.
--   3. The divisor is worked out once and defended. The report divides every
--      column by units_per_box, and a zero there would return NULL into all of
--      them — a blank row, which reads as "no stock" rather than "no packing".
--      A check constraint on items already makes a zero unstorable, so this is
--      belt and braces rather than a fix; it is here because the cost is
--      nothing and the failure would be silent. Test 46 pins the constraint
--      down so the guarantee is checked rather than assumed.
--
-- The signature changes, so the function is DROPPED first: `create or replace`
-- cannot add a column to a returns-table function.
-- ============================================================

drop function if exists closing_stock_report(uuid, date, uuid, uuid);

create or replace function closing_stock_report(
  p_org uuid, p_date date default current_date, p_location uuid default null, p_section uuid default null
) returns table (
  section_id uuid, section_code text, section_name text, sort_order integer,
  item_id uuid, item_code text, pack text, item_name text, units_per_box integer,
  item_type text,
  opening numeric, purchase numeric, production numeric, sales numeric, other numeric, closing numeric,
  opening_units numeric, closing_units numeric, is_negative boolean
) language sql stable as $$
  select
    -- A material has no mestri section and never will. It is given a heading of
    -- its own rather than being dropped in with the finished goods that happen
    -- to be unassigned, which is what "OTHERS" means to this shop.
    case when i.type = 'finished_good' then sec.id end,
    case when i.type = 'finished_good' then sec.code end,
    case i.type
      when 'raw_material'    then 'RAW MATERIAL'
      when 'packing_material' then 'PACKING MATERIAL'
      else coalesce(sec.name, 'OTHERS') end,
    case i.type
      when 'raw_material'    then 1001
      when 'packing_material' then 1002
      else coalesce(sec.sort_order, 999) end,
    i.id, i.item_code, pt.code, i.name, i.units_per_box,
    i.type::text,
    -- opening: everything before today
    round(coalesce(sum(sl.qty_base) filter (where sl.txn_date < p_date), 0) / upb.n, 3),
    -- purchase: goods bought in, and nothing else
    round(coalesce(sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type = 'purchase'), 0) / upb.n, 3),
    -- production: what the kitchen made today. For a raw material this is the
    -- consuming side, which is negative and belongs in "other" — production_in
    -- only ever lands on a finished good.
    round(coalesce(sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type = 'production_in'), 0) / upb.n, 3),
    -- sales: goods sold, shown positive.
    round(coalesce(-sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type = 'sale'), 0) / upb.n, 3),
    -- other: the net of everything else — returns, transfers, adjustments, van
    -- movements, and the raw material production consumed. Signed, so the row
    -- still adds up left to right.
    round(coalesce(sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type not in ('purchase', 'production_in', 'sale')), 0)
          / upb.n, 3),
    -- closing: everything up to and including today
    round(coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date), 0) / upb.n, 3),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <  p_date), 0),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date), 0),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date), 0) < 0
  from items i
  -- One divisor, worked out once. The coalesce is defensive: a zero packing
  -- cannot be stored today, and if that ever changed the report would report
  -- the item's own units rather than a row of nulls.
  cross join lateral (select coalesce(nullif(i.units_per_box, 0), 1)::numeric as n) upb
  left join sections sec on sec.id = i.section_id
  left join pack_types pt on pt.id = i.pack_type_id
  left join stock_ledger sl on sl.item_id = i.id
       and (p_location is null or sl.location_id = p_location)
  where i.org_id = p_org and i.is_active
    -- A section filter is a filter on mestri sections, so it can only ever mean
    -- finished goods. Asking for one and being shown the sugar as well would
    -- make the sub-totals on that section wrong.
    and (p_section is null or i.section_id = p_section)
  group by sec.id, sec.code, sec.name, sec.sort_order, i.id, i.item_code, pt.code, i.name,
           i.units_per_box, i.type, upb.n
  order by
    case i.type when 'raw_material' then 1001 when 'packing_material' then 1002
                else coalesce(sec.sort_order, 999) end,
    case i.type
      when 'raw_material'    then 'RAW MATERIAL'
      when 'packing_material' then 'PACKING MATERIAL'
      else coalesce(sec.name, 'OTHERS') end,
    i.item_code;
$$;
