-- ============================================================
-- DB acceptance test: T12a phase 3 — incentives, route profit, driver stops. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_van uuid; v_veh uuid; v_route uuid; v_route2 uuid; v_cash uuid;
  v_cust uuid; v_cust2 uuid; v_cust3 uuid; v_item uuid; v_item2 uuid; v_exec uuid; v_driver uuid; v_trip uuid; v_inv uuid; v_inv2 uuid; v_inv3 uuid; v_ret uuid;
  r record; n int; q numeric;
  uid_owner uuid := gen_random_uuid(); uid_exec uuid := gen_random_uuid(); uid_driver uuid := gen_random_uuid(); uid_store uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into routes (org_id, name) values (v_org, 'GUNTUR LINE') returning id into v_route;
  insert into routes (org_id, name) values (v_org, 'ONGOLE LINE') returning id into v_route2;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order) values (v_org, 'CASH', 'Cash', true, false, 1) returning id into v_cash;
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_exec, 'Ravi', 'sales_exec') returning id into v_exec;
  insert into staff (org_id, auth_uid, full_name, role, daily_wage) values (v_org, uid_driver, 'Suri', 'driver', 500) returning id into v_driver;
  insert into customers (org_id, name, town, mobile1, route_id) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746', v_route) returning id into v_cust;
  insert into customers (org_id, name, town, mobile1, route_id) values (v_org, 'RAVI STORES', 'GUNTUR', '9000000002', v_route) returning id into v_cust2;
  insert into customers (org_id, name, town, mobile1, route_id) values (v_org, 'ONGOLE MART', 'ONGOLE', '9000000003', v_route2) returning id into v_cust3;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, 32, 12, 42, 30) returning id into v_item;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '21', '10/- KAJU BURFI', v_uom, v_pack, 24, 8, 85, 60) returning id into v_item2;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table) values (v_org, v_item, v_loc, 'opening', current_date, 3200, 'test'), (v_org, v_item2, v_loc, 'opening', current_date, 2400, 'test');

  -- ===== salesman assignment: by route, then stamped on invoices and receipts =====
  assert assign_sales_exec(v_exec, v_route) = 2, 'two customers on the route';
  select sales_exec_name into r from v_customer_list where id = v_cust; assert r.sales_exec_name = 'Ravi';
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));   -- 2688
  perform set_invoice_status(v_inv, 'confirmed');
  select sales_exec_id into r from invoices where id = v_inv; assert r.sales_exec_id = v_exec, 'invoice stamped from the customer';
  -- a sales exec who makes a bill for an unassigned customer is its salesman
  perform set_config('request.jwt.claim.sub', uid_exec::text, true);
  v_inv3 := save_invoice(jsonb_build_object('customer_id', v_cust3, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item2, 'boxes', 1, 'rate', 85)));   -- 2040
  perform set_invoice_status(v_inv3, 'confirmed');
  select sales_exec_id into r from invoices where id = v_inv3; assert r.sales_exec_id = v_exec, 'maker stamped';
  perform save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date), jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 1000)));
  select collected_by into r from receipts where customer_id = v_cust; assert r.collected_by = v_exec, 'receipt stamped with the collector';
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  -- a return against the first invoice: 1 box fresh return
  v_ret := save_sales_return(jsonb_build_object('customer_id', v_cust, 'invoice_id', v_inv, 'return_date', current_date, 'kind', 'fresh_return', 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));   -- 1344

  -- ===== incentive schemes =====
  insert into incentive_schemes (org_id, name, basis, rate) values (v_org, '1% of net sales', 'sales_pct', 1);
  insert into incentive_schemes (org_id, name, basis, rate) values (v_org, '2% of collection', 'collection_pct', 2);
  insert into incentive_schemes (org_id, name, basis, rate) values (v_org, '₹5 a box', 'per_box', 5);
  insert into incentive_schemes (org_id, name, basis, rate) values (v_org, '₹100 a new shop', 'per_new_customer', 100);
  insert into incentive_schemes (org_id, name, basis, slabs) values (v_org, 'Target slab', 'slab', '[{"from":0,"to":3000,"pct":0.5},{"from":3000,"pct":2}]');
  insert into incentive_schemes (org_id, name, basis, rate, is_active) values (v_org, 'Old scheme', 'sales_pct', 9, false);
  -- Ravi: sales 2688 + 2040 = 4728, returns 1344, net 3384, collection 1000, boxes 3, new customers 2 (both first billed this month)
  select count(*) into n from incentive_statement(v_org, current_date, v_exec); assert n = 5, format('five live schemes, got %s', n);
  select earned, net_sales, sales, returns into r from incentive_statement(v_org, current_date, v_exec) where basis = 'sales_pct';
  assert r.sales = 4728 and r.returns = 1344 and r.net_sales = 3384 and r.earned = 33.84, format('sales pct %s', to_jsonb(r));
  select earned, collection into r from incentive_statement(v_org, current_date, v_exec) where basis = 'collection_pct'; assert r.collection = 1000 and r.earned = 20, format('collection %s', to_jsonb(r));
  select earned, boxes into r from incentive_statement(v_org, current_date, v_exec) where basis = 'per_box'; assert r.boxes = 3 and r.earned = 15, format('boxes %s', to_jsonb(r));
  select earned, new_customers into r from incentive_statement(v_org, current_date, v_exec) where basis = 'per_new_customer'; assert r.new_customers = 2 and r.earned = 200, format('new %s', to_jsonb(r));
  select earned into r from incentive_statement(v_org, current_date, v_exec) where basis = 'slab'; assert r.earned = 67.68, format('slab 2%% of 3384 = %s', r.earned);
  select count(*) into n from incentive_statement(v_org, current_date) where staff_name = 'Suri' and basis = 'sales_pct' and earned = 0; assert n = 1, 'driver listed with zero';
  select count(*) into n from incentive_statement(v_org, current_date) where staff_name = 'Owner'; assert n = 0, 'owner not in any scheme';
  select count(*) into n from incentive_statement(v_org, (current_date - interval '1 month')::date, v_exec) where earned <> 0; assert n = 0, 'last month empty';

  -- ===== a van trip on the route: sales, collection, expenses, wages =====
  insert into vehicles (org_id, vehicle_number, route_id, driver_id) values (v_org, 'AP07TX1234', v_route, v_driver) returning id into v_veh;
  select location_id into v_van from vehicles where id = v_veh;
  v_trip := create_trip(jsonb_build_object('vehicle_id', v_veh, 'route_id', v_route, 'driver_id', v_driver, 'trip_date', current_date, 'opening_km', 1000));
  perform van_load(v_trip, v_loc, jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 10)));
  perform set_trip_status(v_trip, 'dispatched');

  -- the driver on the phone
  perform set_config('request.jwt.claim.sub', uid_driver::text, true);
  select id, route_name into r from my_open_trip(); assert r.id = v_trip and r.route_name = 'GUNTUR LINE', 'driver sees own trip';
  select count(*) into n from trip_stops(v_trip); assert n = 2, format('two stops on the route, got %s', n);
  v_inv2 := save_invoice(jsonb_build_object('customer_id', v_cust2, 'invoice_date', current_date, 'location_id', v_van, 'trip_id', v_trip), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 3, 'rate', 42)));   -- 4032
  perform set_invoice_status(v_inv2, 'confirmed');
  perform save_receipt(jsonb_build_object('customer_id', v_cust2, 'receipt_date', current_date, 'trip_id', v_trip, 'vehicle_id', v_veh), jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 2000)));
  select bills, billed, delivered, collected, array_length(pending_delivery, 1) as pend into r from trip_stops(v_trip) where customer_id = v_cust2;
  assert r.bills = 1 and r.billed = 4032 and r.delivered = 0 and r.collected = 2000 and r.pend = 1, format('stop %s', to_jsonb(r));
  perform mark_delivered(v_inv2, 'org/photo.jpg', 'Ravi (shop boy)', null);
  select status::text as st, delivery_photo, receiver_name, delivered_by into r from invoices where id = v_inv2;
  assert r.st = 'delivered' and r.delivery_photo = 'org/photo.jpg' and r.receiver_name = 'Ravi (shop boy)' and r.delivered_by = v_driver, format('delivered %s', to_jsonb(r));
  select delivered, pending_delivery into r from trip_stops(v_trip) where customer_id = v_cust2; assert r.delivered = 1 and r.pending_delivery = '{}'::uuid[];
  select sales_exec_id into r from invoices where id = v_inv2; assert r.sales_exec_id = v_exec, 'customer''s salesman wins over the driver';
  select sum(gap) into q from trip_settlement(v_trip); assert q = 7, format('van has 7 boxes left, %s', q);
  -- someone with no invoice rights and not the driver cannot mark a delivery
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_store, 'Store', 'store_keeper');
  perform set_config('request.jwt.claim.sub', uid_store::text, true);
  begin
    perform mark_delivered(v_inv, null, null, null); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Only the trip%', sqlerrm; end;

  -- owner settles
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  perform settle_trip(v_trip, v_loc, 1080, 600, null);

  -- ===== route profitability =====
  -- GUNTUR LINE: sales 2688 (godown, customer route) + 4032 (trip) = 6720; returns 1344; cogs = 5 boxes × 32 × 30 = 4800
  -- trips 1, km 80, expenses 600, wages 500; collection 3000
  select * into r from route_profitability(v_org, current_date, current_date) where route_name = 'GUNTUR LINE';
  assert r.sales = 6720 and r.returns = 1344 and r.cogs = 4800 and r.gross_margin = 576 and r.trips = 1 and r.km = 80
     and r.trip_expenses = 600 and r.driver_wages = 500 and r.net_profit = -524 and r.collection = 3000 and r.invoices = 2 and r.boxes = 5 and r.customers = 2
     and r.sales_per_km = 84 and r.margin_pct = -7.8, format('guntur %s', to_jsonb(r));
  -- ONGOLE LINE: 2040 sales, cogs 24 × 60 = 1440
  select * into r from route_profitability(v_org, current_date, current_date) where route_name = 'ONGOLE LINE';
  assert r.sales = 2040 and r.cogs = 1440 and r.net_profit = 600 and r.trips = 0 and r.margin_pct = 29.4, format('ongole %s', to_jsonb(r));
  select count(*) into n from route_profitability(v_org, current_date, current_date); assert n = 2, 'no "No route" row without activity';

  -- a sales exec can only read what RLS allows; the statement is org-wide by design (reports module)
  reset role;
  raise notice 'OK: phase 3 — salesman assigned by route and stamped on invoices/receipts, five incentive bases with a slab, driver sees own trip and stops, van sale + receipt + delivery proof from the phone, route profitability ties (sales, returns, cost, trip expenses, wages, km)';
end $$;

rollback;
