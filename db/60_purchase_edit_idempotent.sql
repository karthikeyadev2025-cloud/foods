-- ============================================================
-- JYOTHI FOODS ERP — 60: SAVING A BILL THAT HAS NOT CHANGED MUST SAVE NOTHING
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- The shop's stock_ledger has one purchase bill holding 127 rows for a single
-- product: sixty-four postings and sixty-three reversals, netting to one bill.
-- Another holds sixty-three. The balance that comes out is RIGHT — they cancel
-- in pairs — but the same bill has been saved sixty-four times, and every save
-- rewrote the ledger.
--
-- That is where the 33 MB holding four rows' worth of stock came from, and it
-- is why save_purchase has been timing out: each save reads and re-nets every
-- row the bill has ever written, so bill number sixty-four does sixty-four
-- times the work of the first. It gets slower the more it happens, and a
-- timeout is what makes the screen save it again. A runaway.
--
-- Whatever starts the loop — an outbox replaying a call that did commit, a
-- hand hitting Save on a screen that looked stuck — the database should not
-- play along. An edit that changes nothing now writes nothing: same supplier,
-- same godown, same date, same bill number, same charges, same money paid,
-- same notes and the same lines at the same boxes and rates, and save_purchase
-- returns the bill untouched. No reversal, no reposting, no journal entry.
--
-- So a replayed save is harmless where it used to be another 2 rows per
-- product, and the first save of a real correction still does everything it
-- did before. The lines are compared on item, boxes and rate: boxes because
-- that is what the shop types (db/50), and a line sent as a bare quantity is
-- divided down to boxes exactly as the line trigger would, so the two forms of
-- the same bill compare equal. Anything that cannot be compared — a product
-- with no packing — fails the comparison and the edit goes ahead as usual,
-- which is the safe direction to fail in.
--
-- This does not clean up the rows already written. They cancel out, the stock
-- is right, and deleting them would be deleting history; db/why_minus.sql
-- names every bill that has them under "saved over and over".
-- ============================================================

create or replace function save_purchase(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; l jsonb; n int := 0;
  v_sub numeric := 0; v_other numeric; v_paid numeric; v_total numeric; v_supplier text;
  v_boxes numeric; v_qty numeric; v_bill_no text;
  v_edit boolean; v_before jsonb; k text;
  v_item uuid; v_locn uuid; v_bal numeric; v_was numeric; v_now numeric; v_short text;
  v_same boolean; v_old_lines text[]; v_new_lines text[];
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A purchase needs at least one line';
  end if;
  v_other := coalesce(nullif(p_header->>'other_charges','')::numeric, 0);
  v_paid  := coalesce(nullif(p_header->>'paid_amount','')::numeric, 0);
  v_id    := nullif(p_header->>'id', '')::uuid;
  v_edit  := v_id is not null;

  if v_edit then
    select bill_no into v_bill_no from purchases where id = v_id and org_id = v_org;
    if v_bill_no is null then raise exception 'Purchase not found'; end if;

    -- ---- nothing changed? then nothing happens ----
    -- Each field is compared against what the update below would actually set,
    -- not against what was sent: a blank bill number means "keep the one it
    -- has", so a payload that omits it has not changed it.
    select p.supplier_id is not distinct from nullif(p_header->>'supplier_id','')::uuid
       and p.location_id is not distinct from nullif(p_header->>'location_id','')::uuid
       and p.bill_date = coalesce(nullif(p_header->>'bill_date','')::date, p.bill_date)
       and p.bill_no   = coalesce(nullif(trim(p_header->>'bill_no'), ''), p.bill_no)
       and round(coalesce(p.other_charges, 0), 2) = round(v_other, 2)
       and round(coalesce(p.paid_amount, 0), 2)   = round(v_paid, 2)
       and p.notes is not distinct from nullif(p_header->>'notes','')
      into v_same
      from purchases p where p.id = v_id;

    if v_same then
      select coalesce(array_agg(sig order by sig), '{}') into v_old_lines
        from (select pi.item_id::text || '|'
                     || round(coalesce(pi.boxes, 0), 3)::text || '|'
                     || round(coalesce(pi.rate, 0), 2)::text as sig
                from purchase_items pi where pi.purchase_id = v_id) a;

      -- A line may arrive as boxes or as a bare quantity. Divide the quantity
      -- down the same way trg_purchase_line would, so both say the same thing.
      select coalesce(array_agg(sig order by sig), '{}') into v_new_lines
        from (select (x->>'item_id') || '|'
                     || round(coalesce(nullif(x->>'boxes','')::numeric,
                                       nullif(x->>'qty','')::numeric
                                         / nullif(coalesce(nullif(it.units_per_box, 0), 1), 0)), 3)::text || '|'
                     || round(coalesce(nullif(x->>'rate','')::numeric, 0), 2)::text as sig
                from jsonb_array_elements(p_lines) x
                left join items it on it.id = (x->>'item_id')::uuid) b;

      v_same := v_old_lines = v_new_lines;
    end if;

    -- `if null then` is false, so anything that could not be compared falls
    -- through to the ordinary edit rather than being silently skipped.
    if v_same then
      return v_id;
    end if;

    if exists (select 1 from purchase_returns where purchase_id = v_id) then
      raise exception 'Purchase % has a return against it. Delete the return first.', v_bill_no
        using errcode = '23503';
    end if;

    select coalesce(jsonb_object_agg(key, val), '{}'::jsonb) into v_before
      from (select item_id::text || '|' || location_id::text as key, sum(qty_base) as val
              from stock_ledger
             where ref_table = 'purchases' and ref_id = v_id
             group by 1) s;

    perform unpost_purchase_stock(v_id);
    perform reverse_journal(v_org, 'purchases', v_id,
                            (select bill_date from purchases where id = v_id),
                            format('Purchase %s corrected', v_bill_no));

    update purchases set
      bill_no       = coalesce(nullif(trim(p_header->>'bill_no'), ''), bill_no),
      supplier_id   = nullif(p_header->>'supplier_id','')::uuid,
      location_id   = (p_header->>'location_id')::uuid,
      bill_date     = coalesce(nullif(p_header->>'bill_date','')::date, bill_date),
      other_charges = v_other,
      paid_amount   = v_paid,
      notes         = nullif(p_header->>'notes','')
    where id = v_id and org_id = v_org
    returning bill_no into v_bill_no;

    delete from purchase_items where purchase_id = v_id;
  else
    v_bill_no := coalesce(nullif(trim(p_header->>'bill_no'), ''), next_doc_no(v_org, 'purchase'));
    insert into purchases (org_id, bill_no, supplier_id, location_id, bill_date, other_charges, paid_amount, notes, created_by)
    values (v_org, v_bill_no, nullif(p_header->>'supplier_id','')::uuid,
            (p_header->>'location_id')::uuid,
            coalesce(nullif(p_header->>'bill_date','')::date, current_date),
            v_other, v_paid, nullif(p_header->>'notes',''), my_staff_id())
    returning id into v_id;
  end if;

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

  if v_edit then
    for k in
      select key from jsonb_object_keys(v_before) as key
      union
      select item_id::text || '|' || location_id::text
        from stock_ledger where ref_table = 'purchases' and ref_id = v_id
    loop
      v_item := split_part(k, '|', 1)::uuid;
      v_locn := split_part(k, '|', 2)::uuid;

      select coalesce(sum(qty_base), 0) into v_bal
        from stock_ledger where item_id = v_item and location_id = v_locn;
      if v_bal >= 0 then continue; end if;

      v_was := coalesce((v_before->>k)::numeric, 0);
      select coalesce(sum(qty_base), 0) into v_now
        from stock_ledger
       where ref_table = 'purchases' and ref_id = v_id
         and item_id = v_item and location_id = v_locn;

      if v_bal - (v_now - v_was) >= 0 then
        select name into v_short from items where id = v_item;
        raise exception 'Purchase % cannot be changed this way — the goods have already gone out, and it would leave less than nothing of "%". Reverse the bills that used them first.', v_bill_no, v_short
          using errcode = '23514';
      end if;
    end loop;
  end if;

  select name into v_supplier from suppliers where id = nullif(p_header->>'supplier_id','')::uuid;
  perform post_journal(v_org, coalesce(nullif(p_header->>'bill_date','')::date, current_date),
    format('Purchase %s — %s', v_bill_no, coalesce(v_supplier, 'cash purchase')), 'purchases', v_id,
    jsonb_build_array(
      jsonb_build_object('account','PURCHASES', 'debit',  v_total),
      jsonb_build_object('account','CREDITORS', 'credit', v_total),
      jsonb_build_object('account','CREDITORS', 'debit',  v_paid),
      jsonb_build_object('account','CASH',      'credit', v_paid)));
  return v_id;
end $$;
