-- ============================================================
-- DB acceptance test: the data-health reports. Rolls back.
--
-- These exist for a live master that has real damage in it, so every fault
-- below is built on purpose and then looked for. The repair is destructive, so
-- it is checked twice: that its dry run touches nothing, and that the real run
-- keeps exactly one of each set.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_kg uuid; v_loc uuid; v_loc2 uuid; v_sec uuid; v_pack uuid; v_cust uuid;
  v_good uuid; v_short uuid; v_bare uuid; v_dup uuid;
  n bigint; r record; v_before numeric; v_after numeric;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into uoms (org_id, code, name, basis) values (v_org, 'KG', 'Kilogram', 'weight') returning id into v_kg;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into stock_locations (org_id, name) values (v_org, 'Shop') returning id into v_loc2;
  insert into sections (org_id, code, name) values (v_org, 'S1', 'LADDU') returning id into v_sec;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into customers (org_id, name) values (v_org, 'P. SRINIVAS (MCL)') returning id into v_cust;

  -- A sound product: nothing about it should ever appear in the problem list.
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, section_id,
                     units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '8', 'HT. MYSOOR PAK(12) 32', v_uom, v_pack, v_sec, 32, 12, 42, 30) returning id into v_good;

  -- A product that will be sold without ever being bought.
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, section_id,
                     units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '10', 'BESEN', v_uom, v_pack, v_sec, 10, 1, 125, 100) returning id into v_short;

  -- The price-list import's leftovers: no rate, no packing, no section, no pack,
  -- no cost. One product, five separate problems.
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '13', '5/- SP H.T', v_uom, 1, 1, 0, 0) returning id into v_bare;

  -- ============ 1. negative stock ============
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_good, v_loc, 'opening', current_date, 1000, 30);
  perform set_invoice_status(save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_short, 'boxes', 18, 'rate', 125))), 'confirmed');

  select * into r from negative_stock() where item_id = v_short;
  assert r.item_id is not null, '30.1 the product sold without stock is not reported';
  assert r.qty_base = -180, format('30.1 expected -180, got %s', r.qty_base);
  assert r.boxes = -18, format('30.1 expected -18 boxes, got %s', r.boxes);
  assert r.went_out = 180, format('30.1 out total wrong: %s', r.went_out);
  assert coalesce(r.came_in, 0) = 0, format('30.1 nothing ever came in, got %s', r.came_in);
  assert r.location_name = 'Godown', '30.1 the godown is not named';
  assert not exists (select 1 from negative_stock() where item_id = v_good),
    '30.1 a product with stock was reported as negative';

  -- Per godown, not per product: short in one place is not cancelled by plenty
  -- in another, because you cannot sell from a shelf that is empty.
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_short, v_loc2, 'opening', current_date, 5000, 100);
  assert exists (select 1 from negative_stock() where item_id = v_short and location_name = 'Godown'),
    '30.2 a surplus elsewhere hid a shortage in the godown';

  -- ============ 2. item problems ============
  select count(*) into n from item_data_problems() where item_id = v_bare;
  assert n = 5, format('30.3 expected five problems on the bare product, got %s', n);
  for r in select problem from item_data_problems() where item_id = v_bare loop
    assert r.problem in ('No rate', 'No packing', 'No section', 'No pack type', 'No cost price'),
      format('30.3 unexpected problem: %s', r.problem);
  end loop;
  assert not exists (select 1 from item_data_problems() where item_id = v_good),
    '30.4 a sound product was reported as a problem';

  -- Every problem carries what to do about it, or the list is just a complaint.
  assert not exists (select 1 from item_data_problems() where coalesce(fix, '') = ''),
    '30.5 a problem was reported with no fix beside it';

  -- The measure faults from 29 come through here too, so one screen shows
  -- everything rather than two half-lists.
  update items set base_uom_id = v_kg, net_weight_g = 250 where id = v_good;
  assert exists (select 1 from item_data_problems() where item_id = v_good and problem = 'Cannot be measured'),
    '30.6 a weight unit with no grams did not reach the item problem list';
  update items set base_uom_id = v_uom, net_weight_g = null where id = v_good;

  -- ============ 3. duplicate rows ============
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '20', '5/- ROUND PALLI CHIKKI (8)', v_uom, 8, 8, 5) returning id into v_dup;
  -- The import run twice: the same opening row, three times over.
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_dup, v_loc, 'opening', current_date, 400, 5),
           (v_org, v_dup, v_loc, 'opening', current_date, 400, 5),
           (v_org, v_dup, v_loc, 'opening', current_date, 400, 5);

  select * into r from duplicate_stock_rows() where item_id = v_dup;
  assert r.copies = 3, format('30.7 expected 3 copies, got %s', r.copies);
  assert not exists (select 1 from duplicate_stock_rows() where item_id = v_good),
    '30.7 a single opening row was called a duplicate';

  -- The dry run must count and change nothing. This is the assertion that
  -- matters: the button says "2 extra rows" before anybody commits to it.
  select coalesce(sum(qty_base), 0) into v_before from stock_ledger where item_id = v_dup;
  assert remove_duplicate_stock_rows() = 2, format('30.8 dry run counted %s', remove_duplicate_stock_rows());
  select coalesce(sum(qty_base), 0) into v_after from stock_ledger where item_id = v_dup;
  assert v_before = v_after, format('30.8 the DRY RUN changed the stock: %s then %s', v_before, v_after);
  assert v_after = 1200, format('30.8 setup wrong, expected 1200: %s', v_after);

  -- The real run keeps exactly one of each set.
  assert remove_duplicate_stock_rows(true) = 2, '30.9 the real run counted wrong';
  select coalesce(sum(qty_base), 0) into v_after from stock_ledger where item_id = v_dup;
  assert v_after = 400, format('30.9 expected one row of 400 left, got %s', v_after);
  assert not exists (select 1 from duplicate_stock_rows() where item_id = v_dup), '30.9 duplicates remain';
  assert remove_duplicate_stock_rows() = 0, '30.9 a second run should find nothing left to do';

  raise notice 'OK: data health — negative stock is reported per product and per godown with its in and out totals and is not hidden by a surplus elsewhere; every unusable product is listed once per fault with the fix beside it, measure faults included; duplicate rows are counted by a dry run that changes nothing, and the real run leaves exactly one of each';
end $$;

rollback;
