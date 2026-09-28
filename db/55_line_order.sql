-- ============================================================
-- JYOTHI FOODS ERP — 55: DOCUMENT LINES CAME BACK IN A RANDOM ORDER
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "The items are not maintaining the same sequence in which they are entered.
--  When the purchase details are printed, the items appear jumbled."
--
-- Every line table's primary key is `id uuid default gen_random_uuid()`, and
-- every screen asked for its lines `order by id`. Ordering by a random number
-- is not an ordering — the line typed first could come back fourth, and the
-- printed bill carried whatever that shuffle produced.
--
-- Nothing in the system had ever recorded the order the shop typed the lines
-- in, so there was nothing to sort by. This adds it.
--
-- NOT ONLY PURCHASES. The same `order by id` is on the sales invoice, the
-- return, the quotation, the sale and purchase order, the delivery challan and
-- the purchase return — seven documents, one mistake, made once and copied. A
-- shop's sales bill printing its lines out of order is worse than a purchase
-- doing it, so all seven are fixed together.
--
-- HOW THE NUMBER IS SET. By a trigger, not by rewriting seven save_* functions.
-- The number then holds for anything that inserts a line — the save screens,
-- the importer, a repair run — and none of those functions has to be rebuilt
-- from an older copy, which is exactly how migration 32's automatic bill number
-- was lost once already.
--
-- ------------------------------------------------------------
-- WHY THERE IS NO BACKFILL. An earlier draft of this file numbered the existing
-- rows with an UPDATE. It failed on the first table, refused by
-- t_invoice_items_guard: a confirmed bill's lines may not be changed. That
-- refusal was doing its job, and it hid something worse than itself.
--
-- invoice_items, purchase_items and sales_return_items each carry a calc
-- trigger that fires ON UPDATE and recomputes qty and amount from boxes:
--
--     new.qty    := new.boxes * new.units_per_box;
--     new.amount := round(new.qty * new.rate, 2);
--
-- An UPDATE that touched nothing but line_no would still have run them, and on
-- any row whose boxes were themselves derived by division (db/50 backfilled
-- them as qty / units_per_box, rounded to three places) the round trip does not
-- come back to the same number. 100 jars in threes is 33.333 boxes is 99.999
-- jars. Posted quantities and posted amounts, on bills already in the ledger,
-- would have shifted by a hair — silently, with no error and nothing on any
-- screen to show it. db/50 avoided exactly this by dropping its trigger before
-- its own backfill.
--
-- So nothing is updated. Old lines keep a NULL line_no and are read in id
-- order, which is the order they come back in today and every day — the same
-- order the backfill would have written down. The true entry order of a
-- document saved before today was never recorded and cannot be recovered; a
-- backfill would only have made the guess permanent, at the price of touching
-- money that was already correct.
--
-- The screens therefore sort NULLS FIRST, then by line number. An old document
-- keeps its order; a line added to one afterwards is numbered from 1 and lands
-- AFTER the un-numbered ones, which is where it was typed. A document saved
-- from today is numbered throughout and NULLS FIRST never comes into it.
-- ============================================================

do $$
declare
  spec text[];
  t text;
  fk text;
begin
  foreach spec slice 1 in array array[
    ['invoice_items',        'invoice_id'],
    ['purchase_items',       'purchase_id'],
    ['sales_return_items',   'return_id'],
    ['quotation_items',      'quotation_id'],
    ['order_items',          'order_id'],
    ['challan_items',        'challan_id'],
    ['purchase_return_items','return_id']
  ] loop
    t  := spec[1];
    fk := spec[2];

    -- Nullable, and left null on every row that already exists. See above.
    execute format('alter table public.%I add column if not exists line_no integer', t);

    -- A child table had no index on the column that reaches its parent, so
    -- every read, every delete of a document's lines, and now every line
    -- number lookup walked the whole table.
    execute format('create index if not exists %I on public.%I (%I)', t || '_' || fk || '_idx', t, fk);
  end loop;
end $$;

/**
 * The next line number within this document.
 *
 * A line that already carries one keeps it, so a caller that knows the order —
 * an importer reading a spreadsheet — can say so.
 *
 * Re-saving a document deletes its lines and inserts them again, so the
 * numbering starts at 1 in the new order. That is right: after an edit, the
 * order on the screen IS the order.
 *
 * On a document whose lines predate this migration, max() over nulls is null
 * and the first line added afterwards takes 1. Sorted nulls first, it lands
 * after the old ones — where it was typed.
 */
create or replace function trg_line_no() returns trigger language plpgsql as $$
declare v_col text := tg_argv[0]; v_parent uuid; v_next integer;
begin
  if new.line_no is not null then return new; end if;
  -- Read the parent id by column name, without needing a composite type for
  -- each of the seven tables.
  v_parent := (to_jsonb(new) ->> v_col)::uuid;
  execute format('select coalesce(max(line_no), 0) + 1 from public.%I where %I = $1', tg_table_name, v_col)
    into v_next using v_parent;
  new.line_no := v_next;
  return new;
end $$;

do $$
declare
  spec text[];
  t text;
  fk text;
begin
  foreach spec slice 1 in array array[
    ['invoice_items',        'invoice_id'],
    ['purchase_items',       'purchase_id'],
    ['sales_return_items',   'return_id'],
    ['quotation_items',      'quotation_id'],
    ['order_items',          'order_id'],
    ['challan_items',        'challan_id'],
    ['purchase_return_items','return_id']
  ] loop
    t  := spec[1];
    fk := spec[2];
    -- BEFORE INSERT only. It must never fire on UPDATE: see the note above on
    -- what the calc triggers do to a posted figure when they are re-run.
    -- `create trigger` is not idempotent, so drop first (the lesson of db/50).
    execute format('drop trigger if exists t_line_no on public.%I', t);
    execute format('create trigger t_line_no before insert on public.%I for each row execute function trg_line_no(%L)', t, fk);
  end loop;
end $$;

-- ------------------------------------------------------------
-- The line views carry the number, so a screen can sort by it.
-- `create or replace view` may only APPEND a column, so line_no goes last on
-- every one of them.
-- ------------------------------------------------------------
create or replace view v_invoice_lines as
select ii.id, ii.invoice_id, ii.item_id, i.item_code, i.name as item_name, pt.code as pack_code,
       ii.units_per_box, ii.boxes, ii.qty, ii.rate, ii.amount, ii.uom_id, ii.qty_base, ii.line_no
from invoice_items ii
join items i on i.id = ii.item_id
left join pack_types pt on pt.id = i.pack_type_id;
alter view v_invoice_lines set (security_invoker = on);

create or replace view v_purchase_lines as
select pi.id, pi.purchase_id, pi.item_id, i.item_code, i.name as item_name, pi.qty, pi.uom_id, u.code as uom_code,
       pi.qty_base, pi.rate, pi.amount, pi.boxes, pi.units_per_box, pi.line_no
from purchase_items pi join items i on i.id = pi.item_id left join uoms u on u.id = pi.uom_id;
alter view v_purchase_lines set (security_invoker = on);

create or replace view v_return_lines as
select ri.id, ri.return_id, ri.item_id, i.item_code, i.name as item_name, i.units_per_box,
       ri.qty, ri.qty / nullif(i.units_per_box, 0) as boxes, ri.uom_id, ri.qty_base, ri.old_rate, ri.new_rate, ri.amount,
       ri.line_no
from sales_return_items ri join items i on i.id = ri.item_id;
alter view v_return_lines set (security_invoker = on);

create or replace view v_quotation_lines as
select qi.id, qi.quotation_id, qi.item_id, i.item_code, i.name as item_name, pt.code as pack_code, qi.units_per_box,
       qi.boxes, qi.qty, qi.rate, qi.amount, qi.uom_id, qi.qty_base, qi.line_no
  from quotation_items qi join items i on i.id = qi.item_id left join pack_types pt on pt.id = i.pack_type_id;
alter view v_quotation_lines set (security_invoker = on);

create or replace view v_order_lines as
select oi.id, oi.order_id, oi.item_id, i.item_code, i.name as item_name, oi.units_per_box, oi.boxes, oi.qty, oi.rate,
       oi.amount, oi.uom_id, oi.qty_base, oi.delivered_base,
       round(oi.delivered_base / nullif(oi.units_per_box, 0), 3) as delivered_boxes,
       round(oi.boxes - oi.delivered_base / nullif(oi.units_per_box, 0), 3) as pending_boxes,
       oi.line_no
  from order_items oi join items i on i.id = oi.item_id;
alter view v_order_lines set (security_invoker = on);

create or replace view v_challan_lines as
select ci.id, ci.challan_id, ci.item_id, i.item_code, i.name as item_name, ci.units_per_box, ci.boxes, ci.qty,
       ci.uom_id, ci.qty_base, ci.line_no
  from challan_items ci join items i on i.id = ci.item_id;
alter view v_challan_lines set (security_invoker = on);

create or replace view v_purchase_return_lines as
select ri.id, ri.return_id, ri.item_id, i.item_code, i.name as item_name, ri.qty, ri.uom_id, u.code as uom_code,
       ri.qty_base, ri.rate, ri.amount, ri.line_no
  from purchase_return_items ri join items i on i.id = ri.item_id left join uoms u on u.id = ri.uom_id;
alter view v_purchase_return_lines set (security_invoker = on);
