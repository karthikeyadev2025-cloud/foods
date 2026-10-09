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
  select id into v_cash from receipt_modes where org_id = v_org and code = 'CASH';

  -- Customer with ₹1000 opening balance
  insert into customers (org_id, name, town, mobile1, opening_balance)
    values (v_org, 'SRINIVAS', 'TENALI', '9849111111', 1000) returning id into v_cust;

  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'101','5/- CHEKODI', v_jar, 6, 1, 30, 20) returning id into v_item;

  -- Create an invoice for ₹600 (1 box @ 30 per jar * 6 jars = 180? boxes=1, rate=30 -> total = 180)
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 50)));

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

  raise notice 'OK: test 49 passed';
end $$;

rollback;
