-- ============================================================
-- DB acceptance test: T5 reports and dashboard.
-- Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_route uuid; v_cust uuid; v_cust2 uuid; v_cash uuid; v_bank uuid; v_brk uuid;
  v_item uuid; v_inv1 uuid; v_inv2 uuid; v_inv3 uuid; r record; n int; q numeric; j jsonb;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into routes (org_id, name) values (v_org, 'Macherla line') returning id into v_route;
  insert into customers (org_id, name, town, mobile1, route_id, opening_balance) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746', v_route, 1000) returning id into v_cust;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'B. SHOP', 'GUNTUR', '9000000002') returning id into v_cust2;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order) values (v_org, 'CASH', 'Cash', true, false, 1) returning id into v_cash;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order) values (v_org, 'BANK', 'Bank', true, false, 2) returning id into v_bank;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order) values (v_org, 'BRK', 'Breakage', false, false, 3) returning id into v_brk;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, 32, 12, 42) returning id into v_item;

  -- Bills: 70 days ago 2,688; 20 days ago 1,344; today 2,688 (cust 1); today 1,344 (cust 2)
  v_inv1 := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date - 70, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv1, 'confirmed');
  v_inv2 := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date - 20, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  perform set_invoice_status(v_inv2, 'confirmed');
  v_inv3 := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv3, 'confirmed');
  perform set_invoice_status(save_invoice(jsonb_build_object('customer_id', v_cust2, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42))), 'confirmed');
  -- Money: 30 days ago 1,000 cash (FIFO → oldest bill); today 500 cash + 200 bank + 100 BRK; a rate-difference return today of 64
  perform save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date - 30), jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 1000)));
  perform save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date),
    jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 500), jsonb_build_object('mode_id', v_bank, 'amount', 200), jsonb_build_object('mode_id', v_brk, 'amount', 100)));
  perform save_sales_return(jsonb_build_object('customer_id', v_cust, 'invoice_id', v_inv3, 'kind', 'rate_difference', 'return_date', current_date),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42, 'new_rate', 41)));

  -- ===== receipts register for today =====
  select * into r from receipts_register(v_org, current_date, current_date) where customer_id = v_cust;
  -- total outstanding before today's collections = 1000 opening + 6720 billed - 1000 paid earlier = 6720
  assert r.total_outstanding = 6720, format('register total outstanding %s', r.total_outstanding);
  assert (r.by_mode->>'CASH')::numeric = 500 and (r.by_mode->>'BANK')::numeric = 200 and (r.by_mode->>'BRK')::numeric = 100, format('by_mode %s', r.by_mode);
  assert r.rate_difference = 64 and r.fresh_return = 0 and r.damage_return = 0;
  assert r.remaining_outstanding = 6720 - 800 - 64, format('remaining %s', r.remaining_outstanding);
  select outstanding into q from v_customer_outstanding where customer_id = v_cust;
  assert q = r.remaining_outstanding, 'register remaining must equal the live outstanding';
  select count(*) into n from receipts_register(v_org, current_date, current_date, v_route); assert n = 1, 'route filter';
  select count(*) into n from receipts_register(v_org, current_date, current_date); assert n = 2, 'both customers have activity/outstanding';

  -- ===== customer ledger =====
  select count(*) into n from customer_ledger(v_cust); assert n = 1 + 3 + 2 + 1, format('ledger rows %s', n);
  select balance into q from customer_ledger(v_cust) order by entry_date desc nulls first, doc_no desc limit 1;
  select balance into q from (select balance from customer_ledger(v_cust)) x order by 1 limit 1;
  select balance into r from customer_ledger(v_cust) where doc = 'Opening'; assert r.balance = 1000, 'opening row';
  select max(balance) into q from customer_ledger(v_cust);
  select balance into q from customer_ledger(v_cust) where doc = 'Rate difference';
  assert q = 6720 - 800 - 64, format('ledger closing balance %s', q);
  -- with a from-date, earlier movements roll into the opening
  select balance into q from customer_ledger(v_cust, current_date, current_date) where doc = 'Opening';
  assert q = 1000 + 2688 + 1344 - 1000, format('ledger opening as at today %s', q);

  -- ===== ageing =====
  select * into r from outstanding_ageing(v_org, current_date) where customer_id = v_cust;
  -- FIFO: both receipts (1000 + 800) settle the oldest bill first → inv1 (70d) 2688 - 1800 = 888 in 60+;
  -- inv2 (20d) 1344 untouched in 16-30; inv3 (today) 2688 - 64 rate difference = 2624 in 0-15
  assert r.b60p = 888 and r.b16_30 = 1344 and r.b0_15 = 2624 and r.b31_60 = 0,
    format('ageing buckets %s/%s/%s/%s', r.b0_15, r.b16_30, r.b31_60, r.b60p);
  assert r.oldest_days = 70 and r.outstanding = 6720 - 800 - 64;

  -- ===== collection by mode =====
  select jsonb_object_agg(code, amount) into j from collection_by_mode(v_org, current_date - 60, current_date);
  assert (j->>'CASH')::numeric = 1500 and (j->>'BANK')::numeric = 200 and (j->>'BRK')::numeric = 100, format('by mode %s', j);

  -- ===== route-wise =====
  select * into r from route_collection(v_org, current_date, current_date) where route_name = 'Macherla line';
  assert r.customers = 1 and r.invoices = 1 and r.sales = 2688 and r.collected = 800 and r.returned = 64, format('route: %s', to_jsonb(r));
  select * into r from route_collection(v_org, current_date, current_date) where route_id is null;
  assert r.customers = 1 and r.sales = 1344, 'customers without a route are still counted';

  -- ===== sales summary =====
  select amount, invoices, boxes into r from sales_summary(v_org, current_date, current_date, 'day');
  assert r.amount = 2688 + 1344 and r.invoices = 2 and r.boxes = 3, format('sales by day: %s', to_jsonb(r));
  select count(*) into n from sales_summary(v_org, current_date - 90, current_date, 'customer'); assert n = 2;
  select group_label, amount into r from sales_summary(v_org, current_date - 90, current_date, 'town') order by amount desc limit 1;
  assert r.group_label = 'MACHARLA' and r.amount = 6720, format('by town: %s %s', r.group_label, r.amount);
  select group_key, boxes, amount into r from sales_summary(v_org, current_date - 90, current_date, 'item');
  assert r.group_key = '8' and r.boxes = 6 and r.amount = 8064, format('by item: %s', to_jsonb(r));
  select count(*) into n from sales_summary(v_org, current_date - 90, current_date, 'month'); assert n between 1 and 3;

  -- ===== dashboard =====
  j := dashboard_summary(v_org, current_date);
  assert (j->>'sales_today')::numeric = 4032 and (j->>'collection_today')::numeric = 800 and (j->>'invoices_today')::int = 2, format('dashboard %s', j);
  assert (j->>'total_outstanding')::numeric = (6720 - 800 - 64) + 1344, format('dashboard outstanding %s', j->>'total_outstanding');
  select count(*) into n from dashboard_activity(v_org, current_date); assert n = 2 + 1 + 1, format('activity rows %s', n);

  reset role;
  raise notice 'OK: reports — register columns tie to live outstanding, ledger running balance, ageing 60+/16-30/0-15, by mode, by route, sales by day/customer/town/item, dashboard';
end $$;

rollback;
