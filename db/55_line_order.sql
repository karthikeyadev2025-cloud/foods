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
-- The line number then holds for anything that inserts a line — the save
-- screens, the importer, a repair run — and none of those functions has to be
-- rebuilt from an older copy, which is exactly how migration 32's automatic
-- bill number was lost once already.
--
-- THE BACKFILL IS HONEST, NOT MAGIC. Documents already saved never recorded
-- their entry order, and it cannot be recovered. They are numbered in the order
-- they happen to come back today, so an old bill at least stops reshuffling
-- between one look and the next. New documents keep the real order.
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

    execute format('alter table public.%I add column if not exists line_no integer', t);

    -- A child table had no index on the column that reaches its parent, so
    -- every read, delete and now every max(line_no) walked the whole table.
    execute format('create index if not exists %I on public.%I (%I)', t || '_' || fk || '_idx', t, fk);

    -- Existing rows: numbered in the order they come back today. Not the order
    -- they were typed — that was never written down — but stable from now on.
    execute format($f$
      update public.%I x set line_no = n.rn
        from (select id, row_number() over (partition by %I order by id) as rn from public.%I) n
       where n.id = x.id and x.line_no is null$f$, t, fk, t);
  end loop;
end $$;

/**
 * The next line number within this document.
 *
 * A line that already carries one keeps it, so a caller that wants to set the
 * order itself still can. Everything else is numbered as it arrives, which is
 * the order somebody typed it.
 *
 * Re-saving a document deletes its lines and inserts them again, so the
 * numbering starts at 1 in the new order — which is right: after an edit, the
 * order on the screen IS the order.
 */
create or replace function trg_line_no() returns trigger language plpgsql as $$
declare v_col text := tg_argv[0]; v_parent uuid; v_next integer;
begin
  if new.line_no is not null then return new; end if;
  -- Read the parent id by column name without needing a composite type for
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
    -- `create trigger` is not idempotent; drop first (the lesson of db/50).
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
