-- ============================================================
-- DB acceptance test: the stock-delete window, and the last two deletes.
-- Rolls back.
--
-- "we want delete option in stock and this option is available only to enter
-- original data — after that we will intimate and then remove that option."
--
-- So the thing being tested is not really the delete. It is that the delete can
-- be TAKEN AWAY, by the shop, on the day they say so, without a new build — and
-- that once it is off it is genuinely off rather than merely hidden from the
-- screen, because a hidden button is not a control.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_item uuid; v_ing uuid;
  v_row bigint; v_row2 bigint; v_raw uuid; v_batch uuid; v_recipe uuid; v_inv uuid;
  v_msg text; n numeric; v_until date;
  uid_owner uuid := gen_random_uuid();
  uid_admin uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_uom;
  insert into uoms (org_id, code, name, basis, weight_g) values (v_org,'KG','Kilogram','weight', 1000) returning id into v_ing;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42) returning id into v_item;

  -- ============================================================
  -- 1. A NEW ORGANISATION STARTS OPEN, because it is about to be typed into.
  -- ============================================================
  assert stock_delete_open(v_org), '41.1 a brand new shop cannot correct its own opening figures';

  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 3200, 30) returning id into v_row;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table)
    values (v_org, v_item, v_loc, 'opening', current_date, 640, 30, 'import') returning id into v_row2;

  assert delete_stock_row(v_row2) = 'deleted', '41.1 an imported row would not delete while open';
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item;
  assert n = 3200, format('41.1 the stock did not come back down: %s', n);

  -- ============================================================
  -- 2. THE SHOP CLOSES IT. This is the whole request.
  -- ============================================================
  assert set_stock_delete_window(null) is null, '41.2 closing it did not return null';
  assert not stock_delete_open(v_org), '41.2 it is still open after being closed';

  begin
    perform delete_stock_row(v_row);
    raise exception '41.2 a stock row was deleted after the window was closed';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%no longer be deleted%', format('41.2 wrong reason: %s', v_msg);
    assert v_msg like '%Setup → Business%', format('41.2 does not say where to re-open it: %s', v_msg);
  end;
  assert exists (select 1 from stock_ledger where id = v_row), '41.2 it went anyway';

  -- ============================================================
  -- 3. AND CAN OPEN IT AGAIN, without a new build. That is the point of it
  --    being a setting rather than a release.
  -- ============================================================
  v_until := set_stock_delete_window(7);
  assert v_until = current_date + 7, format('41.3 opened until %s', v_until);
  assert stock_delete_open(v_org), '41.3 seven days from today is not open';
  assert delete_stock_row(v_row) = 'deleted', '41.3 it would not delete once re-opened';

  -- ============================================================
  -- 4. IT CLOSES BY ITSELF. A tick box stays ticked; a date does not. Walk the
  --    stored date into the past exactly as the calendar would.
  -- ============================================================
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 3200, 30) returning id into v_row;
  update orgs set stock_delete_until = current_date - 1 where id = v_org;
  assert not stock_delete_open(v_org), '41.4 a window that ran out yesterday is still open';
  begin
    perform delete_stock_row(v_row);
    raise exception '41.4 a stock row was deleted after the window had run out';
  exception when sqlstate '42501' then null;
  end;

  --    The last day counts as open, not as over.
  update orgs set stock_delete_until = current_date where id = v_org;
  assert stock_delete_open(v_org), '41.5 the last day of the window was treated as past';

  -- ============================================================
  -- 5. ONLY AN OWNER MAY OPEN IT. Who may USE the delete is an ordinary
  --    permission; who may switch it on is a narrower question, because this is
  --    the one control that lets a figure be made wrong with nothing left over.
  -- ============================================================
  insert into staff (org_id, full_name, role, auth_uid) values (v_org, 'K. RAMESH', 'admin', uid_admin);
  perform set_config('request.jwt.claim.sub', uid_admin::text, true);
  begin
    perform set_stock_delete_window(30);
    raise exception '41.6 an admin opened the stock ledger for deletion';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%owner%', format('41.6 wrong reason: %s', v_msg);
  end;
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);

  --    And a length nobody meant is refused rather than quietly clamped.
  begin
    perform set_stock_delete_window(9999);
    raise exception '41.7 a window of 9999 days was accepted';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%1 and 90%', format('41.7 wrong reason: %s', v_msg);
  end;
  perform set_stock_delete_window(30);

  -- ============================================================
  -- 6. A PRODUCTION BATCH. Open ones go; closed ones give back what they took
  --    and take back what they made.
  -- ============================================================
  insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit, purchase_rate)
    values (v_org,'RM-SUGAR','SUGAR','raw_material', v_ing, 1, 1, 45) returning id into v_raw;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_raw, v_loc, 'opening', current_date, 500000, 45);

  v_recipe := save_recipe(jsonb_build_object('item_id', v_item, 'pieces_per_plate', 384),
                          jsonb_build_array(jsonb_build_object('ingredient_id', v_raw, 'qty_per_plate', 9)));

  v_batch := open_production_batch(jsonb_build_object(
    'item_id', v_item, 'plates', 10, 'production_date', current_date::text, 'location_id', v_loc));

  -- A recipe a batch has been made from is held by it.
  begin
    perform delete_master('recipe', v_recipe);
    raise exception '41.8 a recipe was deleted from under a batch made with it';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%production batch%', format('41.8 wrong reason: %s', v_msg);
  end;

  -- An open batch has made nothing yet.
  assert delete_document('batch', v_batch) = 'deleted', '41.9 an open batch would not delete';
  assert not exists (select 1 from production_batches where id = v_batch), '41.9 still there';

  -- Now a closed one: raw material out, finished boxes in.
  v_batch := open_production_batch(jsonb_build_object(
    'item_id', v_item, 'plates', 10, 'production_date', current_date::text, 'location_id', v_loc));
  -- The chief's actuals: without them a closed batch consumes nothing and the
  -- test would be proving that an empty batch unwinds to nothing.
  update batch_ingredients set actual_qty = expected_qty where batch_id = v_batch;
  update production_batches set actual_boxes = 100, actual_pieces = 100 * 32 * 12 where id = v_batch;
  perform close_production_batch(v_batch);

  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_loc;
  assert n > 3200, format('41.10 the batch put nothing on the shelf: %s', n);
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_raw;
  assert n < 500000, '41.10 the batch consumed no raw material';

  assert delete_document('batch', v_batch) = 'deleted', '41.10 a closed batch would not delete';
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_loc;
  assert n = 3200, format('41.10 the finished boxes stayed on the shelf: %s', n);
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_raw;
  assert n = 500000, format('41.10 the raw material did not come back: %s', n);
  assert not exists (select 1 from item_batches where production_batch_id = v_batch),
    '41.10 the expiry lot it created was left behind';

  --    But not once what it made has been sold under its batch number.
  v_batch := open_production_batch(jsonb_build_object(
    'item_id', v_item, 'plates', 10, 'production_date', current_date::text, 'location_id', v_loc));
  -- The chief's actuals: without them a closed batch consumes nothing and the
  -- test would be proving that an empty batch unwinds to nothing.
  update batch_ingredients set actual_qty = expected_qty where batch_id = v_batch;
  update production_batches set actual_boxes = 100, actual_pieces = 100 * 32 * 12 where id = v_batch;
  perform close_production_batch(v_batch);
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 150, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  begin
    perform delete_document('batch', v_batch);
    raise exception '41.11 a batch was undone after its goods had been sold';
  exception when sqlstate '23503' or sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%' || (select batch_no from production_batches where id = v_batch) || '%',
      format('41.11 does not name the batch: %s', v_msg);
  end;

  -- 7. A recipe nothing was ever made from goes.
  perform set_invoice_status(v_inv, 'cancelled');
  perform delete_document('batch', v_batch);
  assert delete_master('recipe', v_recipe) = 'deleted', '41.12 an unused recipe would not delete';
  assert not exists (select 1 from recipes where id = v_recipe), '41.12 still there';
  assert not exists (select 1 from recipe_ingredients where recipe_id = v_recipe), '41.12 its lines were left behind';

  raise notice 'OK: the stock-delete window — a new shop starts open so its opening figures can be corrected, the owner closes it in one call and the delete is genuinely refused rather than merely hidden, it can be re-opened without a new build, it runs out by itself with the last day counting as open, only an owner may set it and only within 1 to 90 days; and the last two screens gained a delete — a production batch gives back the raw material and takes the boxes off the shelf unless they have been sold under its batch number, and a recipe goes once no batch stands on it';
end $$;

rollback;
