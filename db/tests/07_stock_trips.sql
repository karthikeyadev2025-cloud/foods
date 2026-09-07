-- ============================================================
-- DB acceptance test: T3 stock reports, trips, van loading, settlement.
-- Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_god uuid; v_van uuid; v_veh uuid; v_trip uuid; v_cust uuid; v_cash uuid;
  v_item8 uuid; v_item2 uuid; v_inv uuid; r record; n int; q numeric;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Main godown') returning id into v_god;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'Shop', 'Town', '9000000001') returning id into v_cust;
  insert into receipt_modes (org_id, code, name) values (v_org, 'CASH', 'Cash') returning id into v_cash;
  insert into sections (org_id, code, name, sort_order) values (v_org, 'S-1', 'CHINNA MASTRY', 2);
  insert into sections (org_id, code, name, sort_order) values (v_org, 'S-10', 'RAMA KRISHNA MESTRI', 1);
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, section_id, units_per_box, pieces_per_unit, unit_rate, reorder_level)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, (select id from sections where org_id = v_org and code = 'S-1'), 32, 12, 42, 64)
    returning id into v_item8;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, section_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '2', '5/- BOONDI LADDU (12) 48', v_uom, v_pack, (select id from sections where org_id = v_org and code = 'S-10'), 48, 12, 40)
    returning id into v_item2;
  insert into vehicles (org_id, vehicle_number) values (v_org, 'AP07AB1234') returning id, location_id into v_veh, v_van;

  -- Opening stock on 01-09: code 8 = 10 boxes, code 2 = 5 boxes
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base) values
    (v_org, v_item8, v_god, 'opening', '2026-09-01', 320), (v_org, v_item2, v_god, 'opening', '2026-09-01', 240);

  -- ===== T3.2 trip: create, load, dispatch =====
  v_trip := create_trip(jsonb_build_object('vehicle_id', v_veh, 'trip_date', '2026-09-02', 'opening_km', 1000));
  select status into r from v_trip_list where id = v_trip; assert r.status = 'planned';
  begin
    perform create_trip(jsonb_build_object('vehicle_id', v_veh));
    raise exception 'second open trip for the same van must fail';
  exception when others then if sqlerrm not like '%already has an open trip%' then raise; end if;
  end;

  perform van_load(v_trip, v_god, jsonb_build_array(jsonb_build_object('item_id', v_item8, 'boxes', 5), jsonb_build_object('item_id', v_item2, 'boxes', 2)));
  select sum(qty_base) into q from stock_ledger where item_id = v_item8 and location_id = v_god; assert q = 320 - 160, format('godown after load: %s', q);
  select sum(qty_base) into q from stock_ledger where item_id = v_item8 and location_id = v_van; assert q = 160, format('van after load: %s', q);
  select status, loaded_boxes into r from v_trip_list where id = v_trip; assert r.status = 'loaded' and r.loaded_boxes = 7, format('trip: %s %s', r.status, r.loaded_boxes);
  select count(*) into n from trip_loading_sheet(v_trip); assert n = 2, 'loading sheet has 2 lines';
  select boxes into q from trip_loading_sheet(v_trip) where item_code = '8'; assert q = 5;

  perform set_trip_status(v_trip, 'dispatched');
  begin
    perform van_load(v_trip, v_god, jsonb_build_array(jsonb_build_object('item_id', v_item8, 'boxes', 1)));
    raise exception 'loading after dispatch must fail';
  exception when others then if sqlerrm not like '%loading is over%' then raise; end if;
  end;

  -- ===== T3.1 closing stock on the trip date, per location =====
  select opening, purchase, sales, closing into r from closing_stock_report(v_org, date '2026-09-02', v_god) where item_code = '8';
  assert r.opening = 10 and r.purchase = 0 and r.sales = 5 and r.closing = 5, format('godown report: %s/%s/%s/%s', r.opening, r.purchase, r.sales, r.closing);
  select opening, purchase, sales, closing into r from closing_stock_report(v_org, date '2026-09-02', v_van) where item_code = '8';
  assert r.opening = 0 and r.purchase = 5 and r.sales = 0 and r.closing = 5, format('van report: %s/%s/%s/%s', r.opening, r.purchase, r.sales, r.closing);
  select opening, closing into r from closing_stock_report(v_org, date '2026-09-02') where item_code = '8';
  assert r.opening = 10 and r.closing = 10, 'all locations: a transfer changes nothing';
  -- grouped by section in sort order: S-10 (order 1) before S-1 (order 2)
  select string_agg(section_code, ',' order by sort_order, item_code) into r from closing_stock_report(v_org, date '2026-09-02');
  assert r.string_agg = 'S-10,S-1', format('section order: %s', r.string_agg);

  -- ===== sale from the van on the trip =====
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', '2026-09-02', 'trip_id', v_trip),
                        jsonb_build_array(jsonb_build_object('item_id', v_item8, 'boxes', 2, 'rate', 42)));
  select location_id, vehicle_id into r from invoices where id = v_inv;
  assert r.location_id = v_van and r.vehicle_id = v_veh, 'a trip invoice sells from the van';
  perform set_invoice_status(v_inv, 'confirmed');
  select sum(qty_base) into q from stock_ledger where item_id = v_item8 and location_id = v_van; assert q = 160 - 64, format('van after sale: %s', q);
  perform save_receipt(jsonb_build_object('customer_id', v_cust, 'trip_id', v_trip, 'vehicle_id', v_veh),
                       jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 2000)));

  -- ===== movements with running balance =====
  select count(*), max(balance_base) into n, q from stock_movements(v_item8, null, null, v_van);
  assert n = 2 and q = 160, format('van movements: %s rows, peak %s', n, q);
  select balance_base into q from stock_movements(v_item8) order by txn_date desc, id desc limit 1;
  assert q = 320 - 64, format('overall running balance %s', q);
  select ref_no into r from stock_movements(v_item8, null, null, v_van) where txn_type = 'sale';
  assert r.ref_no = (select invoice_no from invoices where id = v_inv), 'movement shows the invoice number';

  -- ===== low stock =====
  select is_low into r from v_item_stock where item_id = v_item8; assert r.is_low = false, 'code 8 at 256 units is not low (reorder 64)';
  update items set reorder_level = 300 where id = v_item8;
  select is_low into r from v_item_stock where item_id = v_item8; assert r.is_low = true;

  -- ===== T3.3 settlement =====
  select loaded, sold, returned, gap into r from trip_settlement(v_trip) where item_code = '8';
  assert r.loaded = 5 and r.sold = 2 and r.returned = 0 and r.gap = 3, format('before settle: %s/%s/%s/%s', r.loaded, r.sold, r.returned, r.gap);
  select sold_value, collected into r from v_trip_list where id = v_trip; assert r.sold_value = 2688 and r.collected = 2000;

  perform settle_trip(v_trip, v_god, 1080, 350, 'ok');
  select status, closing_km, expenses into r from v_trip_list where id = v_trip;
  assert r.status = 'settled' and r.closing_km = 1080 and r.expenses = 350;
  select sum(qty_base) into q from stock_ledger where item_id = v_item8 and location_id = v_van; assert q = 0, format('van emptied: %s', q);
  select sum(qty_base) into q from stock_ledger where item_id = v_item8 and location_id = v_god; assert q = 320 - 64, format('godown after unload: %s', q);
  select loaded, sold, returned, gap into r from trip_settlement(v_trip) where item_code = '8';
  assert r.loaded = 5 and r.sold = 2 and r.returned = 3 and r.gap = 0, format('after settle: %s/%s/%s/%s', r.loaded, r.sold, r.returned, r.gap);
  select loaded, sold, returned, gap into r from trip_settlement(v_trip) where item_code = '2';
  assert r.loaded = 2 and r.sold = 0 and r.returned = 2 and r.gap = 0;
  begin
    perform settle_trip(v_trip, v_god);
    raise exception 'settling twice must fail';
  exception when others then if sqlerrm not like '%cannot settle%' then raise; end if;
  end;
  -- the van is free for a new trip
  perform create_trip(jsonb_build_object('vehicle_id', v_veh));
  -- ledger never updated, only appended
  select count(*) into n from stock_ledger where org_id = v_org; assert n = 2 + 4 + 1 + 4, format('ledger rows: %s', n);

  reset role;
  raise notice 'OK: stock reports per location and section, running-balance movements, low stock; trip load → sell → settle with gap = 0';
end $$;

rollback;
