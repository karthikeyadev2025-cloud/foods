-- ============================================================
-- JYOTHI FOODS ERP — 50: A PURCHASE IS TYPED IN BOXES, LIKE A BILL
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- From the shop: "In Purchase, the values entered for the box are being counted
-- as the pack type." And, in the same breath: "the Purchase should be designed
-- the same way as the Sales Invoice, with the same format and functionality."
--
-- Those are one fault and one fix. The two screens were never built the same
-- way underneath:
--
--   invoice_items    the operator types BOXES. The trigger does
--                    qty = boxes × units_per_box, then the base quantity.
--   purchase_items   the operator typed a QUANTITY and a UNIT, and the screen
--                    handed it the item's BASE unit — a jar, not a box.
--
-- So "51" on a purchase of 1/- KALAJAM(12) meant fifty-one JARS. Fifty-one jars
-- is 4.25 boxes, and 4.25 is exactly what the stock report showed. The stock
-- was understated twelvefold and the bill value with it.
--
-- This makes a purchase line the same shape as a bill line: boxes in,
-- units_per_box snapshotted from the product, qty and the base quantity worked
-- out from those two. One way of counting across the whole system.
--
-- HISTORY IS NOT REWRITTEN. Purchases already entered were entered in jars and
-- posted in jars, and that is what the godown actually received as far as this
-- database is concerned. The backfill below runs with the trigger DROPPED so it
-- cannot recompute a single posted figure — it only writes down, after the
-- fact, how many boxes those jars amounted to. Correcting a purchase that was
-- typed wrong is a job for the person who knows what really arrived: delete it
-- (db/47) and enter it again.
-- ============================================================

alter table purchase_items add column if not exists boxes numeric;
alter table purchase_items add column if not exists units_per_box numeric;

comment on column purchase_items.boxes is
  'What the operator typed. qty = boxes × units_per_box, exactly as on a bill.';

-- Dropped, not disabled: with no trigger on the table the backfill cannot touch
-- qty, qty_base or amount even by accident, and numeric division rounding can
-- never feed back into a posted figure.
drop trigger if exists t_purchase_items_base on purchase_items;

update purchase_items pi
   set units_per_box = coalesce(nullif(i.units_per_box, 0), 1),
       boxes = round(pi.qty / coalesce(nullif(i.units_per_box, 0), 1), 3)
  from items i
 where i.id = pi.item_id
   and (pi.boxes is null or pi.units_per_box is null);

/**
 * A purchase line, calculated the way a bill line is.
 *
 * Boxes is what the shop counts, so boxes is what is typed and everything else
 * follows. A caller that still sends a bare qty (the importer, an older client)
 * keeps working: the boxes are worked back out of it instead.
 */
create or replace function trg_purchase_line() returns trigger language plpgsql as $$
declare it items%rowtype;
begin
  select * into it from items where id = new.item_id;

  -- Packing and unit are SNAPSHOTTED from the product, never typed on the
  -- screen — the same rule a bill line follows, so re-packing a product later
  -- cannot silently re-quantify a purchase already entered.
  if coalesce(new.units_per_box, 0) = 0 then new.units_per_box := coalesce(nullif(it.units_per_box, 0), 1); end if;
  new.uom_id := coalesce(new.uom_id, it.base_uom_id);

  if new.boxes is not null then
    new.qty := new.boxes * new.units_per_box;
  else
    new.boxes := round(new.qty / nullif(new.units_per_box, 0), 3);
  end if;

  new.qty_base := to_base_qty(new.item_id, new.qty, new.uom_id);
  new.amount   := round(new.qty * new.rate, 2);
  return new;
end $$;

drop trigger if exists t_purchase_items_calc on purchase_items;
create trigger t_purchase_items_calc before insert or update on purchase_items
  for each row execute function trg_purchase_line();

/**
 * Save a purchase, in boxes.
 *
 * The subtotal is now added up FROM THE SAVED ROWS rather than from what was
 * sent. It used to be totalled from the incoming qty, which meant the header
 * and the lines were each doing their own arithmetic and only agreed as long as
 * both used the same units — precisely the thing that had gone wrong.
 */
create or replace function save_purchase(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; l jsonb; n int := 0;
  v_sub numeric := 0; v_other numeric; v_paid numeric; v_total numeric; v_supplier text;
  v_boxes numeric; v_qty numeric; v_bill_no text;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A purchase needs at least one line';
  end if;
  v_other := coalesce(nullif(p_header->>'other_charges','')::numeric, 0);
  v_paid  := coalesce(nullif(p_header->>'paid_amount','')::numeric, 0);

  -- From db/32, and carried forward here deliberately: a purchase with no
  -- supplier bill number takes the next number from its own series, so it can
  -- still be found, printed and chased.
  v_bill_no := coalesce(nullif(trim(p_header->>'bill_no'), ''), next_doc_no(v_org, 'purchase'));

  insert into purchases (org_id, bill_no, supplier_id, location_id, bill_date, other_charges, paid_amount, notes, created_by)
  values (v_org, v_bill_no, nullif(p_header->>'supplier_id','')::uuid,
          (p_header->>'location_id')::uuid,
          coalesce(nullif(p_header->>'bill_date','')::date, current_date),
          v_other, v_paid, nullif(p_header->>'notes',''), my_staff_id())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    v_boxes := nullif(l->>'boxes', '')::numeric;
    v_qty   := nullif(l->>'qty', '')::numeric;
    if coalesce(v_boxes, v_qty, 0) <= 0 then
      raise exception 'Line %: quantity must be greater than zero', n;
    end if;

    insert into purchase_items (purchase_id, item_id, boxes, qty, uom_id, qty_base, rate, amount)
    values (v_id, (l->>'item_id')::uuid, v_boxes, coalesce(v_qty, 0),
            nullif(l->>'uom_id','')::uuid, 0,
            coalesce(nullif(l->>'rate','')::numeric, 0), 0);
  end loop;

  select coalesce(sum(amount), 0) into v_sub from purchase_items where purchase_id = v_id;

  v_total := round(v_sub + v_other, 2);
  if v_paid > v_total then raise exception 'Paid amount % exceeds the bill total %', v_paid, v_total; end if;
  update purchases set subtotal = v_sub, total = v_total where id = v_id;

  perform post_purchase_stock(v_id);

  select name into v_supplier from suppliers where id = nullif(p_header->>'supplier_id','')::uuid;
  perform post_journal(v_org, coalesce(nullif(p_header->>'bill_date','')::date, current_date),
    -- v_bill_no, not the header: an automatic number has to reach the ledger too.
    format('Purchase %s — %s', v_bill_no, coalesce(v_supplier, 'cash purchase')), 'purchases', v_id,
    jsonb_build_array(
      jsonb_build_object('account','PURCHASES', 'debit',  v_total),
      jsonb_build_object('account','CREDITORS', 'credit', v_total),
      jsonb_build_object('account','CREDITORS', 'debit',  v_paid),
      jsonb_build_object('account','CASH',      'credit', v_paid)));
  return v_id;
end $$;

-- ── the same functionality a bill has ───────────────────────────────────────
/**
 * What this supplier last charged for each product — the buying side of
 * customer_last_rates() from db/48, and asked for in the same sentence: "the
 * same format and functionality".
 *
 * A purchase has no cancelled state, so every line counts.
 */
create or replace function supplier_last_rates(p_supplier uuid)
returns table (
  item_id      uuid,
  item_code    text,
  item_name    text,
  rate         numeric,
  boxes        numeric,
  purchase_id  uuid,
  bill_no      text,
  bill_date    date,
  times_bought bigint)
language sql stable security definer set search_path = public as $$
  with mine as (
    select pi.item_id, pi.rate, pi.boxes, p.id as purchase_id, p.bill_no, p.bill_date
      from purchase_items pi
      join purchases p on p.id = pi.purchase_id
     where p.org_id = my_org_id() and p.supplier_id = p_supplier
  ),
  latest as (
    select distinct on (m.item_id) m.* from mine m
     order by m.item_id, m.bill_date desc, m.purchase_id desc
  ),
  counted as (select m.item_id, count(*) as times_bought from mine m group by m.item_id)
  select l.item_id, it.item_code, it.name, l.rate, l.boxes,
         l.purchase_id, l.bill_no, l.bill_date, c.times_bought
    from latest l
    join items it on it.id = l.item_id
    join counted c on c.item_id = l.item_id
   order by l.bill_date desc, it.name;
$$;

revoke execute on function supplier_last_rates(uuid) from public, anon;
grant  execute on function supplier_last_rates(uuid) to authenticated;

-- The detail view carries the boxes too, so the purchase reads back the way it
-- was typed rather than only in jars. `create or replace view` cannot drop or
-- reorder existing columns, so the two are appended at the end.
create or replace view v_purchase_lines as
select pi.id, pi.purchase_id, pi.item_id, i.item_code, i.name as item_name, pi.qty, pi.uom_id, u.code as uom_code,
       pi.qty_base, pi.rate, pi.amount, pi.boxes, pi.units_per_box
from purchase_items pi join items i on i.id = pi.item_id left join uoms u on u.id = pi.uom_id;
alter view v_purchase_lines set (security_invoker = on);
