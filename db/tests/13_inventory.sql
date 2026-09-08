-- ============================================================
-- DB acceptance test: T9 inventory depth. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_kg uuid; v_box uuid; v_pack uuid; v_loc uuid; v_loc2 uuid; v_cust uuid; v_item uuid; v_sugar uuid; v_recipe uuid;
  b1 uuid; b2 uuid; v_tr uuid; v_cnt uuid; v_inv uuid; v_van uuid; v_trip uuid;
  r record; n int; q numeric; j jsonb; v_code text;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into uoms (org_id, code, name, basis, weight_g) values (v_org, 'KG', 'Kilogram', 'weight', 1000) returning id into v_kg;
  insert into uoms (org_id, code, name, basis, sort_order) values (v_org, 'BOX', 'Box', 'box', 0) returning id into v_box;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into stock_locations (org_id, name) values (v_org, 'Shop') returning id into v_loc2;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate, shelf_life_days)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, 32, 12, 42, 30) returning id into v_item;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, type, purchase_rate)
    values (v_org, 'SUGAR', 'Sugar', v_kg, 1, 1, 'raw_material', 40) returning id into v_sugar;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table) values (v_org, v_sugar, v_loc, 'opening', current_date - 60, 100, 'test');

  -- ===== two production batches → two item batches with expiry =====
  v_recipe := save_recipe(jsonb_build_object('item_id', v_item, 'pieces_per_plate', 96), jsonb_build_array(jsonb_build_object('ingredient_id', v_sugar, 'qty_per_plate', 1, 'uom_id', v_kg)));
  b1 := open_production_batch(jsonb_build_object('item_id', v_item, 'plates', 4, 'production_date', current_date - 25, 'location_id', v_loc));
  perform update_batch_actuals(b1, jsonb_build_object('actual_boxes', 1));  -- 1 box = 32 jars
  perform close_production_batch(b1);
  b2 := open_production_batch(jsonb_build_object('item_id', v_item, 'plates', 8, 'production_date', current_date - 2, 'location_id', v_loc));
  perform update_batch_actuals(b2, jsonb_build_object('actual_boxes', 2));
  perform close_production_batch(b2);
  select count(*) into n from v_item_batches where item_id = v_item; assert n = 2, format('item batches %s', n);
  select expiry_date, produced_base into r from v_item_batches where production_batch_id = b1;
  assert r.expiry_date = current_date - 25 + 30 and r.produced_base = 32, format('batch 1 %s', to_jsonb(r));
  select count(*) into n from stock_ledger where item_id = v_item and txn_type = 'production_in' and batch_id is not null; assert n = 2, 'production rows carry the batch';

  -- ===== FEFO balances: sell 1.5 boxes → the older batch goes first =====
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1.5, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  select remaining_boxes, consumed_base, days_to_expiry into r from batch_balances(v_org, v_item) where batch_id = (select id from item_batches where production_batch_id = b1);
  assert r.remaining_boxes = 0 and r.consumed_base = 32 and r.days_to_expiry = 5, format('old batch first: %s', to_jsonb(r));
  select remaining_boxes, consumed_base into r from batch_balances(v_org, v_item) where batch_id = (select id from item_batches where production_batch_id = b2);
  assert r.remaining_boxes = 1.5 and r.consumed_base = 16, format('new batch keeps the rest: %s', to_jsonb(r));
  select count(*) into n from expiry_report(v_org, 30); assert n = 1, format('one batch left expiring within 30 days: %s', n);
  select count(*) into n from expiry_report(v_org, 7); assert n = 0, 'the batch with stock expires in 28 days';
  -- FEFO suggestion for loading 1 box: the newer batch is all that is left
  select count(*), max(batch_no) into n, v_code from fefo_suggest(v_item, 1);
  assert n = 1, format('fefo rows %s', n);
  select take_boxes, remaining_boxes into r from fefo_suggest(v_item, 1); assert r.take_boxes = 1 and r.remaining_boxes = 1.5;
  select sum(take_boxes) into q from fefo_suggest(v_item, 5); assert q = 1.5, 'suggests only what exists';

  -- ===== barcodes =====
  assert ean13_check('200000000011') = '2000000000114', format('check digit %s', ean13_check('200000000011'));
  n := generate_barcodes(); assert n = 2, format('box + unit code for the one finished item: %s', n);
  n := generate_barcodes(); assert n = 0, 'idempotent';
  select barcode into v_code from v_item_barcodes where item_id = v_item and level = 'box';
  assert length(v_code) = 13 and v_code = ean13_check(left(v_code, 12)), format('valid EAN-13 %s', v_code);
  select item_id, level into r from item_by_barcode(v_code); assert r.item_id = v_item and r.level = 'box';
  select barcode into v_code from v_item_barcodes where item_id = v_item and level = 'unit';
  select level into r from item_by_barcode(' ' || v_code || ' '); assert r.level = 'unit', 'scanner whitespace tolerated';
  select count(*) into n from item_by_barcode('123'); assert n = 0;

  -- ===== godown transfer =====
  v_tr := save_stock_transfer(jsonb_build_object('from_location', v_loc, 'to_location', v_loc2, 'notes', 'for the shop'), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1)));
  select transfer_no, total_boxes, from_name, to_name into r from v_stock_transfers where id = v_tr;
  assert r.transfer_no is not null and r.total_boxes = 1 and r.from_name = 'Godown' and r.to_name = 'Shop', format('transfer %s', to_jsonb(r));
  assert location_stock_base(v_item, v_loc) = 96 - 48 - 32, format('godown after transfer %s', location_stock_base(v_item, v_loc));
  assert location_stock_base(v_item, v_loc2) = 32, 'shop received it';
  begin
    perform save_stock_transfer(jsonb_build_object('from_location', v_loc, 'to_location', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1))); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Pick two different locations%', sqlerrm; end;

  -- ===== physical count at the godown: system 16 jars (0.5 box), counted 1 box → +16 =====
  v_cnt := open_stock_count(v_loc, current_date, null, 'month end');
  select count_no, line_count, counted_count, status into r from v_stock_counts where id = v_cnt;
  assert r.count_no is not null and r.line_count = 1 and r.counted_count = 0 and r.status = 'open', format('count sheet %s', to_jsonb(r));
  select system_boxes into q from v_stock_count_lines where count_id = v_cnt; assert q = 0.5, format('system boxes %s', q);
  begin
    perform open_stock_count(v_loc); raise exception 'should fail';
  exception when others then assert sqlerrm like 'A count is already open%', sqlerrm; end;
  begin
    perform post_stock_count(v_cnt); raise exception 'should fail';
  exception when others then assert sqlerrm = 'Nothing has been counted yet', sqlerrm; end;
  n := update_stock_count(v_cnt, jsonb_build_array(jsonb_build_object('item_id', v_item, 'counted_boxes', 1)));
  select variance_boxes, variance_value into r from v_stock_count_lines where count_id = v_cnt; assert r.variance_boxes = 0.5 and r.variance_value = 16 * 42, format('variance %s', to_jsonb(r));
  -- a sale after the sheet was opened must not be double counted: the live figure is what matters
  perform set_invoice_status(save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 0.25, 'rate', 42))), 'confirmed');
  n := post_stock_count(v_cnt); assert n = 1, format('adjustments posted %s', n);
  assert location_stock_base(v_item, v_loc) = 32, format('godown now equals the count: %s', location_stock_base(v_item, v_loc));
  select posted_base into q from v_stock_count_lines where count_id = v_cnt; assert q = 24, format('posted variance against live figure (16 − 8 + 24 = 32): %s', q);
  select status, posted_by_name, variance_count into r from v_stock_counts where id = v_cnt; assert r.status = 'posted' and r.posted_by_name = 'Owner' and r.variance_count = 1;
  select count(*) into n from stock_ledger where ref_table = 'stock_counts' and ref_id = v_cnt and txn_type = 'adjustment'; assert n = 1;
  begin
    perform update_stock_count(v_cnt, '[]'::jsonb); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Count % is posted', sqlerrm; end;
  v_cnt := open_stock_count(v_loc2);
  perform cancel_stock_count(v_cnt);
  select status into r from stock_counts where id = v_cnt; assert r.status = 'cancelled';

  -- ===== dashboard keys =====
  j := dashboard_summary(v_org);
  assert (j->>'expiring_batches')::int = 0 and (j->>'open_counts')::int = 0, format('dashboard %s', j);

  reset role;
  raise notice 'OK: inventory — batches born on production close with shelf-life expiry, FEFO balances and pick list, expiry report, EAN-13 barcodes generated / looked up, godown transfer, physical count with variance posted against the live figure';
end $$;

rollback;
