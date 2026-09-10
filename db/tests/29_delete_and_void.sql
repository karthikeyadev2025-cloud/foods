-- ============================================================
-- DB acceptance test: deleting records and documents. Rolls back.
--
-- The refusals matter more than the deletions here. A delete that goes through
-- when it should not is silent: the stock figure drifts, or a bill starts
-- naming a product that no longer exists, and nobody finds out for months.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_spare uuid; v_sup uuid; v_mode uuid; v_head uuid;
  v_used uuid; v_unused uuid; v_fresh uuid; v_inv uuid; v_q uuid; v_rec uuid; v_pay uuid; v_pu uuid; v_pu2 uuid; v_pr uuid;
  v_msg text; v_stock numeric; n bigint;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into receipt_modes (org_id, code, name) values (v_org, 'CASH', 'Cash') returning id into v_mode;
  insert into expense_heads (org_id, name) values (v_org, 'Diesel') returning id into v_head;
  insert into suppliers (org_id, name) values (v_org, 'SUGAR TRADERS') returning id into v_sup;
  insert into customers (org_id, name, town) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA') returning id into v_cust;
  insert into customers (org_id, name, town) values (v_org, 'TYPED BY MISTAKE', 'NOWHERE') returning id into v_spare;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '8', 'HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42, 30) returning id into v_used;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '99', 'ADDED BY MISTAKE', v_uom, 10, 1, 5) returning id into v_unused;

  -- ============ records ============
  -- 1. Nothing points at these two, so they simply go.
  assert delete_master('item', v_unused) = 'deleted', '29.1 an unused product would not delete';
  assert delete_master('customer', v_spare) = 'deleted', '29.1 an unused customer would not delete';
  assert not exists (select 1 from items where id = v_unused), '29.1 still there';

  -- 2. Once a product has been bought or sold it must not vanish, and the
  --    refusal has to say what is in the way and what to do instead.
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_used, v_loc, 'opening', current_date, 1000, 30);
  begin
    perform delete_master('item', v_used);
    raise exception '29.2 a product with stock history was deleted';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%stock movement%', format('29.2 does not name what blocks it: %s', v_msg);
    assert v_msg like '%inactive%', format('29.2 does not offer the way out: %s', v_msg);
  end;

  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_used, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');

  -- 3. A customer who has been billed is the same story.
  begin
    perform delete_master('customer', v_cust);
    raise exception '29.3 a billed customer was deleted';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%bill%', format('29.3 wrong reason: %s', v_msg);
  end;

  -- ============ documents ============
  -- 4. A quotation posts nothing, so it goes outright.
  v_q := save_quotation(
    jsonb_build_object('customer_id', v_cust, 'quote_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_used, 'boxes', 1, 'rate', 42)));
  assert delete_document('quotation', v_q) = 'deleted', '29.4 quotation would not delete';
  assert not exists (select 1 from quotation_items where quotation_id = v_q), '29.4 lines left behind';

  -- 5. An invoice is cancelled rather than removed — a bill the customer holds
  --    a copy of should not disappear from our side.
  assert delete_document('invoice', v_inv) = 'cancelled', '29.5 invoice should cancel, not delete';
  assert (select status from invoices where id = v_inv) = 'cancelled', '29.5 not cancelled';
  select coalesce(sum(qty_base), 0) into v_stock from stock_ledger where item_id = v_used;
  assert v_stock = 1000, format('29.5 cancelling did not put the goods back: %s', v_stock);

  -- 6. A receipt: the money goes off the customer's account and the ledger
  --    entry is reversed.
  v_rec := save_receipt(
    jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date::text),
    jsonb_build_array(jsonb_build_object('mode_id', v_mode, 'amount', 500)));
  assert delete_document('receipt', v_rec) = 'deleted', '29.6 receipt would not delete';
  assert not exists (select 1 from receipt_lines where receipt_id = v_rec), '29.6 lines left behind';
  select coalesce(sum(debit) - sum(credit), 0) into v_stock
    from journal_lines jl join journal_entries je on je.id = jl.entry_id
   where je.ref_table = 'receipts' and je.ref_id = v_rec;
  assert v_stock = 0, format('29.6 the ledger was not reversed: %s', v_stock);

  -- 7. A payment, the same.
  v_pay := save_payment(jsonb_build_object('payment_date', current_date::text, 'mode_id', v_mode,
                                           'expense_head_id', v_head, 'amount', 2500));
  assert delete_document('payment', v_pay) = 'deleted', '29.7 payment would not delete';

  -- 8. A purchase whose goods are still sitting there deletes, and takes its
  --    stock back out.
  v_pu := save_purchase(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_used, 'qty', 100, 'uom_id', v_uom, 'rate', 30)));
  select coalesce(sum(qty_base), 0) into v_stock from stock_ledger where item_id = v_used;
  assert v_stock = 1100, format('29.8 the purchase did not add stock: %s', v_stock);
  assert delete_document('purchase', v_pu) = 'deleted', '29.8 purchase would not delete';
  select coalesce(sum(qty_base), 0) into v_stock from stock_ledger where item_id = v_used;
  assert v_stock = 1000, format('29.8 the stock did not come back out: %s', v_stock);

  -- 9. THE ONE THAT MATTERS. Goods bought, then sold. Deleting the purchase now
  --    would leave the shop showing less than nothing of that product, so it is
  --    refused and the product is named.
  -- A product with no opening stock, so the only stock it ever has is what this
  -- purchase brought in. (The stock ledger is append-only, so the test cannot
  -- clear an opening balance to make this case — it has to start from nothing.)
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '77', 'KAJU KATLI 250G', v_uom, 32, 1, 300, 220) returning id into v_fresh;
  v_pu2 := save_purchase(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_fresh, 'qty', 100, 'uom_id', v_uom, 'rate', 220)));
  perform set_invoice_status(save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_fresh, 'boxes', 3, 'rate', 300))), 'confirmed');
  select coalesce(sum(qty_base), 0) into v_stock from stock_ledger where item_id = v_fresh;
  assert v_stock = 4, format('29.9 setup wrong: expected 100 in and 96 out, got %s', v_stock);
  begin
    perform delete_document('purchase', v_pu2);
    raise exception '29.9 deleted a purchase whose goods had already been sold';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%KAJU%', format('29.9 does not name the product: %s', v_msg);
  end;
  select coalesce(sum(qty_base), 0) into v_stock from stock_ledger where item_id = v_fresh;
  assert v_stock = 4, format('29.9 the refusal still changed the stock: %s', v_stock);

  -- 10. A purchase with a return against it is refused too, naming the reason.
  v_pr := save_purchase_return(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'return_date', current_date::text, 'purchase_id', v_pu2),
    jsonb_build_array(jsonb_build_object('item_id', v_fresh, 'qty', 2, 'uom_id', v_uom, 'rate', 220)));
  begin
    perform delete_document('purchase', v_pu2);
    raise exception '29.10 deleted a purchase that has a return against it';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%return%', format('29.10 wrong reason: %s', v_msg);
  end;

  -- 11. The return itself comes off cleanly, putting its stock back.
  assert delete_document('purchase_return', v_pr) = 'deleted', '29.11 purchase return would not delete';
  select coalesce(sum(qty_base), 0) into v_stock from stock_ledger where item_id = v_fresh;
  assert v_stock = 4, format('29.11 stock wrong after undoing the return: %s', v_stock);

  raise notice 'OK: delete — an unused product or customer goes outright, one that is on a document is refused with what blocks it and the offer of Inactive; a quotation deletes, an invoice cancels and puts its goods back, a receipt and a payment reverse their ledger entry, a purchase takes its stock back out, and a purchase whose goods have already been sold is refused by name';
end $$;

rollback;
