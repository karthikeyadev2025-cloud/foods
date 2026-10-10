-- ============================================================
-- DB acceptance test: receipt opening balance allocation & purchase edit stock.
-- Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_loc uuid; v_cust uuid; v_sup uuid; v_item uuid;
  v_cash uuid; v_inv uuid; v_rcpt uuid; v_rcpt2 uuid; v_pur uuid;
  v_open_rem numeric; v_bal numeric; r record;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');

  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into suppliers (org_id, name, town, mobile1) values (v_org,'SUGAR TRADERS','GUNTUR','9849000000') returning id into v_sup;
  -- Nothing seeds receipt modes: the shop names its own ways of taking money in
  -- Setup, so a test that needs one creates it, as every other test here does.
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order)
    values (v_org,'CASH','Cash', true, false, 1) returning id into v_cash;

  -- Customer with ₹1000 opening balance
  insert into customers (org_id, name, town, mobile1, opening_balance)
    values (v_org, 'SRINIVAS', 'TENALI', '9849111111', 1000) returning id into v_cust;

  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'101','5/- CHEKODI', v_jar, 6, 1, 30, 20) returning id into v_item;

  -- A bill of 600: 2 boxes of 6 jars at 50 a jar.
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 50)));
  -- Confirmed, or it is not a bill yet: a draft owes nothing, takes no part in
  -- first-in-first-out, and moves no stock.
  perform set_invoice_status(v_inv, 'confirmed');

  assert (select balance from v_invoice_balance where invoice_id = v_inv) = 600, 'Invoice balance should be 600';

  -- ============================================================
  -- 1. Customer pays ₹400. It must clear Opening Balance FIRST, not the invoice.
  -- ============================================================
  v_rcpt := save_receipt(
    jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date::text),
    jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 400)));

  -- Invoice balance should STILL be ₹600 (not reduced directly from invoice)
  select balance into v_bal from v_invoice_balance where invoice_id = v_inv;
  assert v_bal = 600, format('49.1 invoice balance should still be 600, got %s', v_bal);

  -- Opening balance remaining should now be 1000 - 400 = 600
  select opening_balance_remaining into v_open_rem from v_customer_list where id = v_cust;
  assert v_open_rem = 600, format('49.1 opening balance remaining should be 600, got %s', v_open_rem);

  -- ============================================================
  -- 2. Customer pays another ₹800. ₹600 clears opening balance, ₹200 to invoice.
  -- ============================================================
  v_rcpt2 := save_receipt(
    jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date::text),
    jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 800)));

  select opening_balance_remaining into v_open_rem from v_customer_list where id = v_cust;
  assert v_open_rem = 0, format('49.2 opening balance remaining should be 0, got %s', v_open_rem);

  -- Invoice balance should now be 600 - 200 = 400
  select balance into v_bal from v_invoice_balance where invoice_id = v_inv;
  assert v_bal = 400, format('49.2 invoice balance should now be 400, got %s', v_bal);

  -- Outstanding ageing report shows remaining opening balance 0
  select opening_balance into v_open_rem from outstanding_ageing(v_org, current_date) where customer_id = v_cust;
  assert v_open_rem = 0, format('49.2 ageing opening balance should be 0, got %s', v_open_rem);

  -- ============================================================
  -- 3. PURCHASE EDIT: Stock report reflects edited bill, not duplicate new purchase
  -- ============================================================
  v_pur := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 10, 'rate', 20)));

  select * into r from closing_stock_report(v_org, current_date, v_loc) where item_id = v_item;
  assert r.purchase = 10, format('49.3 initial purchase should be 10 boxes, got %s', r.purchase);

  -- Correct the purchase to 15 boxes
  perform save_purchase(
    jsonb_build_object('id', v_pur, 'location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 15, 'rate', 20)));

  select * into r from closing_stock_report(v_org, current_date, v_loc) where item_id = v_item;
  assert r.purchase = 15, format('49.3 corrected purchase in stock report should be 15 boxes, got %s', r.purchase);
  -- and the godown holds what is left after the two boxes already sold
  assert r.closing = 15 - 2, format('49.3 closing should be 13 boxes, got %s', r.closing);

  -- The correction is three rows, not two: the bill as it was, that posting
  -- taken back, and the bill as it is now. All three sit on the BILL's date —
  -- a reversal dated today would read as a fresh purchase tomorrow morning
  -- and is exactly what db/58 was written to stop (db/59 made it run at all).
  assert (select count(*) from stock_ledger
           where ref_table = 'purchases' and ref_id = v_pur) = 3,
    format('49.4 a corrected bill should leave 3 stock rows, found %s',
           (select count(*) from stock_ledger where ref_table = 'purchases' and ref_id = v_pur));
  assert not exists (select 1 from stock_ledger
                      where ref_table = 'purchases' and ref_id = v_pur
                        and txn_date <> (select bill_date from purchases where id = v_pur)),
    '49.4 a stock row of the corrected bill is dated away from the bill';
  assert (select sum(qty_base) from stock_ledger
           where ref_table = 'purchases' and ref_id = v_pur) = 15 * 6,
    '49.4 the three rows must net to the corrected bill';
  -- Somebody owns the reversal. created_by is a uuid, and reaching for max()
  -- on it is what broke every purchase edit until db/59.
  assert not exists (select 1 from stock_ledger
                      where ref_table = 'purchases' and ref_id = v_pur and created_by is null),
    '49.4 a stock row of the corrected bill names nobody';

  raise notice 'OK: a receipt settles the opening balance before any bill, and the ageing report says so; a purchase can be corrected — the old posting is taken back on the BILL''s own date, so the stock report shows the corrected bill rather than a second purchase, and every row names who made it';
end $$;

rollback;
