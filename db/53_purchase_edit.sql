-- ============================================================
-- JYOTHI FOODS ERP — 53: EDIT A PURCHASE
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "purchase edit option i want."
--
-- There never was one. A sales invoice can be opened and changed while it is a
-- draft; a purchase posted its stock and its ledger the moment it was saved and
-- the screen said so — "Purchases are final on save." That was a decision made
-- for the machine's convenience, not the shop's. A supplier's bill gets typed
-- with the wrong rate, the wrong date, a line left off. The shop should fix it,
-- not delete it and start again.
--
-- WHY THIS IS NOT SIMPLY "UPDATE THE ROWS"
--
-- The stock ledger is append-only, on purpose. There is no delete policy on it
-- (db/03), and the last time posting code tried to DELETE its old rows and
-- insert again, RLS silently removed nothing and every re-post doubled the
-- stock — the bug fixed in db/05. So an edit here does what the ledger is built
-- for: it writes the OPPOSITE rows, leaving the old ones where they are, and
-- then posts the new bill. The journal is corrected the same way, with a
-- reversing entry, which is what reverse_journal already does for a delete.
--
-- Nothing is rewritten. Anybody reading the ledger afterwards sees the goods
-- arrive, sees them taken back out, and sees them arrive again as corrected.
-- That is the honest record of what happened, and an auditor can follow it.
--
-- WHAT AN EDIT REFUSES
--   * A purchase with a purchase return against it — the return has to go first,
--     exactly as it does for a delete.
--   * An edit that would leave less than nothing of a product, and only when
--     this edit is what took it below. The shop already has items standing
--     negative from before the system was loaded; refusing to correct those
--     bills would be the opposite of helpful.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Posting may happen more than once in a purchase's life now,
--    so the guard becomes "is the previous posting still standing?"
--    rather than "has anything ever been posted?".
--
--    The NET is what matters: +50 boxes and -50 boxes cancel, and a
--    purchase whose rows sum to zero has been taken back and may be
--    posted again. This is the same test post_invoice_stock has used
--    since db/05.
-- ------------------------------------------------------------
create or replace function post_purchase_stock(p_purchase uuid)
returns void language plpgsql as $$
declare p purchases%rowtype; v_net numeric;
begin
  select * into p from purchases where id = p_purchase;
  if not found then return; end if;

  select coalesce(sum(qty_base), 0) into v_net
    from stock_ledger where ref_table = 'purchases' and ref_id = p_purchase;

  if v_net <> 0 then
    raise exception 'Purchase % is already posted to stock. Corrections are adjustment rows.', p.bill_no;
  end if;

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select p.org_id, pi.item_id, p.location_id, 'purchase', p.bill_date,
         pi.qty_base, pi.rate, 'purchases', p.id, p.created_by
  from purchase_items pi where pi.purchase_id = p_purchase;
end $$;

-- ------------------------------------------------------------
-- 2. Take a posted purchase back out of stock, by writing the
--    opposite rows. Returns how many it wrote.
-- ------------------------------------------------------------
create or replace function unpost_purchase_stock(p_purchase uuid, p_on date default null)
returns int language plpgsql as $$
declare v_net numeric; n int := 0;
begin
  select coalesce(sum(qty_base), 0) into v_net
    from stock_ledger where ref_table = 'purchases' and ref_id = p_purchase;
  if v_net = 0 then return 0; end if;   -- never posted, or already taken back

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select org_id, item_id, location_id, txn_type, coalesce(p_on, current_date),
         -qty_base, rate, 'purchases', ref_id, created_by
    from stock_ledger
   where ref_table = 'purchases' and ref_id = p_purchase;
  get diagnostics n = row_count;
  return n;
end $$;

-- ------------------------------------------------------------
-- 3. save_purchase, now with an edit path.
--
--    An id in the header means "this bill, corrected". Everything
--    else is as db/50 left it: boxes are what gets typed, the totals
--    come from the saved rows, and a bill with no supplier number of
--    its own takes the next number from its series (db/32).
-- ------------------------------------------------------------
create or replace function save_purchase(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; l jsonb; n int := 0;
  v_sub numeric := 0; v_other numeric; v_paid numeric; v_total numeric; v_supplier text;
  v_boxes numeric; v_qty numeric; v_bill_no text;
  v_edit boolean; v_before jsonb; k text;
  v_item uuid; v_locn uuid; v_bal numeric; v_was numeric; v_now numeric; v_short text;
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

    if exists (select 1 from purchase_returns where purchase_id = v_id) then
      raise exception 'Purchase % has a return against it. Delete the return first.', v_bill_no
        using errcode = '23503';
    end if;

    -- What this bill put into stock before the edit, per item and godown. Kept
    -- so the check at the end can tell "this edit took it below nothing" from
    -- "it was below nothing already" — the shop has items standing negative
    -- from goods consumed before the system was loaded, and those bills must
    -- still be correctable.
    select coalesce(jsonb_object_agg(key, val), '{}'::jsonb) into v_before
      from (select item_id::text || '|' || location_id::text as key, sum(qty_base) as val
              from stock_ledger
             where ref_table = 'purchases' and ref_id = v_id
             group by 1) s;

    perform unpost_purchase_stock(v_id);
    perform reverse_journal(v_org, 'purchases', v_id, current_date,
                            format('Purchase %s corrected', v_bill_no));

    -- The bill keeps its number unless the supplier's own number is being
    -- typed in. An edit must never draw a fresh one from the series: the
    -- number is on a piece of paper in the shop's file.
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

  -- On an edit, check what the correction did to the shelf — every product this
  -- bill touched before or touches now.
  --
  -- The test is "did THIS EDIT push it under", not "is it under". Those are not
  -- the same question, and getting them confused would block the corrections the
  -- shop most needs: SUGAR and PALM OIL stand well below nothing because
  -- production consumed raw material that was never entered as bought, and the
  -- bills for that raw material are exactly what somebody is about to sit down
  -- and fix. So: refused only where the shelf was level or better before the
  -- edit and is below nothing after it. Raising here rolls the whole correction
  -- back — the bill, the stock and the money together.
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

      -- Where the shelf stood before this edit: what it holds now, less what
      -- the edit changed about this bill's own contribution to it.
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

grant execute on function unpost_purchase_stock(uuid, date) to authenticated;
