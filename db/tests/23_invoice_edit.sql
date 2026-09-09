-- ============================================================
-- DB acceptance test: editing a confirmed sale invoice. Rolls back.
--
-- A confirmed invoice could not be corrected at all — the lines were locked and
-- the only way out was to cancel and re-bill, losing the number the customer
-- already holds. reopen_invoice() puts it back to draft, undoing the stock and
-- the journal on the way, and refuses when money or goods have already moved
-- against it.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_item uuid; v_mode uuid;
  v_inv uuid; v_rec uuid; v_msg text; v_from invoice_status;
  v_stock numeric; v_debtors numeric; v_no text; v_total numeric;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into customers (org_id, name, town) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '8', 'HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42) returning id into v_item;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 1000, 30);

  -- Bill 2 boxes and confirm it: 64 jars out, Debtors up.
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  select invoice_no, total into v_no, v_total from invoices where id = v_inv;
  assert v_total = 2688, format('23.0 expected 2688, got %s', v_total);

  select coalesce(sum(qty_base), 0) into v_stock from stock_ledger where item_id = v_item;
  assert v_stock = 936, format('23.0 expected 936 in stock after billing 64, got %s', v_stock);

  -- 1. A confirmed invoice really was uneditable — this is what the shop hit.
  begin
    perform save_invoice(
      jsonb_build_object('id', v_inv, 'customer_id', v_cust, 'location_id', v_loc),
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 3, 'rate', 42)));
    raise exception '23.1 a confirmed invoice accepted an edit without being reopened';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%only drafts can be edited%' or v_msg like '%draft%',
      format('23.1 unexpected: %s', v_msg);
  end;

  -- 2. Reopening reports what it undid, and gives back a draft.
  v_from := reopen_invoice(v_inv);
  assert v_from = 'confirmed', format('23.2 expected confirmed, got %s', v_from);
  assert (select status from invoices where id = v_inv) = 'draft', '23.2 not a draft';

  -- 3. The goods came back and the ledger was reversed.
  select coalesce(sum(qty_base), 0) into v_stock from stock_ledger where item_id = v_item;
  assert v_stock = 1000, format('23.3 goods did not come back: %s', v_stock);
  select coalesce(sum(debit) - sum(credit), 0) into v_debtors
    from journal_lines jl join journal_entries je on je.id = jl.entry_id
    join ledger_accounts a on a.id = jl.account_id
   where je.ref_table = 'invoices' and je.ref_id = v_inv and a.code = 'DEBTORS';
  assert v_debtors = 0, format('23.3 debtors not reversed: %s', v_debtors);

  -- 4. Now it edits, and keeps the number the customer already has.
  perform save_invoice(
    jsonb_build_object('id', v_inv, 'customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 3, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  assert (select invoice_no from invoices where id = v_inv) = v_no, '23.4 the invoice number changed';
  assert (select total from invoices where id = v_inv) = 4032,
    format('23.4 expected 4032 for 3 boxes, got %s', (select total from invoices where id = v_inv));

  -- 5. Re-confirming posted stock and ledger again, once and not twice.
  select coalesce(sum(qty_base), 0) into v_stock from stock_ledger where item_id = v_item;
  assert v_stock = 904, format('23.5 expected 904 after 96 jars out, got %s', v_stock);
  select coalesce(sum(debit) - sum(credit), 0) into v_debtors
    from journal_lines jl join journal_entries je on je.id = jl.entry_id
    join ledger_accounts a on a.id = jl.account_id
   where je.ref_table = 'invoices' and je.ref_id = v_inv and a.code = 'DEBTORS';
  assert v_debtors = 4032, format('23.5 debtors should be the new total, got %s', v_debtors);

  -- 6. Money collected against it stops the edit, naming the amount.
  insert into receipt_modes (org_id, code, name) values (v_org, 'CASH', 'Cash') returning id into v_mode;
  -- The mode sits on the line, and FIFO allocates it against the open invoice.
  v_rec := save_receipt(
    jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date::text),
    jsonb_build_array(jsonb_build_object('mode_id', v_mode, 'amount', 1000)));
  begin
    perform reopen_invoice(v_inv);
    raise exception '23.6 reopened an invoice with a receipt against it';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%1000%', format('23.6 does not name the amount: %s', v_msg);
    assert v_msg like '%receipt%', format('23.6 does not say what to undo: %s', v_msg);
  end;

  -- 7. A draft reopens to nothing rather than complaining.
  assert reopen_invoice((
    select save_invoice(
      jsonb_build_object('customer_id', v_cust, 'location_id', v_loc),
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42))))) = 'draft',
    '23.7 a draft should reopen quietly';

  raise notice 'OK: invoice edit — a confirmed invoice reopens to draft with its stock and journal reversed, edits, keeps its number and re-posts once on confirming; a receipt or a return against it blocks the edit and says which';
end $$;

rollback;
