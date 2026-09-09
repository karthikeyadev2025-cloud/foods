-- ============================================================
-- JYOTHI FOODS ERP — 32: NUMBER A PURCHASE WHEN THE SUPPLIER DID NOT
--
-- `purchases.bill_no` held whatever was typed, and blank was allowed, so a
-- purchase entered without one had no number at all. Nothing to search for,
-- nothing on the journal narration, nothing to say to the accountant on the
-- phone — the row could only be found by supplier and date.
--
-- That is most of this shop's buying. Sugar, oil and besan come off a mandi
-- slip with no printed number, and the office was being asked to invent one.
--
-- So: left blank, a purchase now takes the next number from its own series,
-- the same next_doc_no() machinery that numbers invoices and receipts. The
-- prefix and the starting number are already configurable at
-- Setup > Numbering, where 'purchase' has always been one of the document
-- types — it simply had nothing calling it.
--
-- Typed in, the supplier's own bill number is kept exactly as it was. That
-- matters and is not a detail to automate away: it is what matches your books
-- to theirs when a payment is disputed, and what stops the same supplier bill
-- being entered twice. Automatic is the fallback for when there is nothing to
-- record, not a replacement for a real reference.
--
-- The journal narration also read the number straight off the caller's header,
-- so an automatic number would not have reached the ledger. It reads the row
-- now.
--
-- FORWARD ONLY. save_purchase lives in 09_transactions.sql; do not go back and
-- edit that, and never run a lower-numbered file after this one.
-- ============================================================

create or replace function save_purchase(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid; l jsonb; n int := 0; v_sub numeric := 0; v_other numeric; v_paid numeric; v_total numeric; v_supplier text; v_bill_no text;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A purchase needs at least one line';
  end if;
  v_other := coalesce(nullif(p_header->>'other_charges','')::numeric, 0);
  v_paid  := coalesce(nullif(p_header->>'paid_amount','')::numeric, 0);

  -- The supplier's number wins whenever there is one; ours fills the gap.
  v_bill_no := coalesce(nullif(trim(p_header->>'bill_no'), ''), next_doc_no(v_org, 'purchase'));

  insert into purchases (org_id, bill_no, supplier_id, location_id, bill_date, other_charges, paid_amount, notes, created_by)
  values (v_org, v_bill_no, nullif(p_header->>'supplier_id','')::uuid,
          (p_header->>'location_id')::uuid,
          coalesce(nullif(p_header->>'bill_date','')::date, current_date),
          v_other, v_paid, nullif(p_header->>'notes',''), my_staff_id())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    if coalesce((l->>'qty')::numeric, 0) <= 0 then raise exception 'Line %: quantity must be greater than zero', n; end if;
    insert into purchase_items (purchase_id, item_id, qty, uom_id, qty_base, rate, amount)
    values (v_id, (l->>'item_id')::uuid, (l->>'qty')::numeric, (l->>'uom_id')::uuid, 0,
            coalesce(nullif(l->>'rate','')::numeric, 0),
            round((l->>'qty')::numeric * coalesce(nullif(l->>'rate','')::numeric, 0), 2));
    v_sub := v_sub + round((l->>'qty')::numeric * coalesce(nullif(l->>'rate','')::numeric, 0), 2);
  end loop;

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
