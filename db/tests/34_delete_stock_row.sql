-- ============================================================
-- DB acceptance test: deleting one stock movement. Rolls back.
--
-- The refusals are the point. The ledger is append-only for everyone else, so
-- this function is a hole cut in that policy on purpose, and the test that
-- matters is that the hole is exactly the right shape: typed and imported rows
-- go, rows a document posted do not, and the stock figure moves by exactly what
-- was removed.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_sup uuid; v_item uuid;
  v_open bigint; v_imported bigint; v_adj bigint; v_sale bigint; v_buy bigint;
  v_inv uuid; v_pu uuid; v_msg text; v_stock numeric; n bigint;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into suppliers (org_id, name) values (v_org,'SUGAR TRADERS') returning id into v_sup;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42, 30) returning id into v_item;

  -- Three rows nobody billed: an opening balance, a row an import signed, and a
  -- hand-posted adjustment.
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 1000, 30) returning id into v_open;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table)
    values (v_org, v_item, v_loc, 'opening', current_date, 320, 30, 'import') returning id into v_imported;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'adjustment', current_date, -20, 30) returning id into v_adj;

  select coalesce(sum(qty_base),0) into v_stock from stock_ledger where item_id = v_item;
  assert v_stock = 1300, format('34.0 setup wrong: %s', v_stock);

  -- 1. The imported row goes, and the stock moves by exactly its own quantity.
  assert delete_stock_row(v_imported) = 'deleted', '34.1 an imported row would not delete';
  select coalesce(sum(qty_base),0) into v_stock from stock_ledger where item_id = v_item;
  assert v_stock = 980, format('34.1 expected 980 after removing 320, got %s', v_stock);
  assert not exists (select 1 from stock_ledger where id = v_imported), '34.1 the row is still there';

  -- A second go at the same row says it is gone rather than pretending to work.
  begin
    perform delete_stock_row(v_imported);
    raise exception '34.2 deleting a row twice reported success';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%not there any more%', format('34.2 wrong reason: %s', v_msg);
  end;

  -- 2. Typed rows go too: an opening balance and an adjustment.
  assert delete_stock_row(v_adj) = 'deleted', '34.3 an adjustment would not delete';
  assert delete_stock_row(v_open) = 'deleted', '34.3 an opening balance would not delete';
  select coalesce(sum(qty_base),0) into v_stock from stock_ledger where item_id = v_item;
  assert v_stock = 0, format('34.3 expected nothing left, got %s', v_stock);

  -- 3. THE ONES THAT MUST NOT GO. Put stock back, then bill against it.
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 1000, 30);
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  select id into v_sale from stock_ledger where ref_table = 'invoices' and ref_id = v_inv limit 1;
  assert v_sale is not null, '34.4 the invoice posted no stock row';

  begin
    perform delete_stock_row(v_sale);
    raise exception '34.4 a sale bill''s stock row was deleted';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%sale bill%', format('34.4 does not name the kind: %s', v_msg);
    assert v_msg like '%cancel%', format('34.4 does not say what to do instead: %s', v_msg);
    -- The bill's own number, so the person can go straight to it.
    assert v_msg like '%' || (select invoice_no from invoices where id = v_inv) || '%',
      format('34.4 does not name the bill: %s', v_msg);
  end;

  v_pu := save_purchase(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 100, 'uom_id', v_uom, 'rate', 30)));
  select id into v_buy from stock_ledger where ref_table = 'purchases' and ref_id = v_pu limit 1;
  begin
    perform delete_stock_row(v_buy);
    raise exception '34.5 a purchase stock row was deleted';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%purchase%', format('34.5 wrong reason: %s', v_msg);
  end;

  -- And nothing was quietly removed while being refused.
  select count(*) into n from stock_ledger where item_id = v_item;
  assert n = 3, format('34.6 expected opening + sale + purchase = 3 rows, got %s', n);

  raise notice 'OK: delete a stock movement — an opening balance, an adjustment and an imported row go, and the stock moves by exactly what was removed; a sale bill''s row and a purchase''s row are refused, named, and left untouched; a row already gone says so instead of reporting success';
end $$;

rollback;
