-- ============================================================
-- DB acceptance test: the stock report shows what the shop BUYS, not only what
-- it makes. Rolls back.
--
-- The fault this pins down was invisible from the screen: purchase bills for
-- sugar saved, posted to stock and reached the ledger, and the stock report
-- looked exactly as it had before, because the report only ever selected
-- finished goods. From the counter there is no difference between a figure that
-- is wrong and a figure that is absent.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_kg uuid; v_loc uuid; v_sec uuid; v_sup uuid; v_pack uuid;
  v_kalajam uuid; v_sugar uuid; v_carton uuid; v_nopack uuid;
  r record; n bigint;
  uid uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into uoms (org_id, code, name, basis, weight_g) values (v_org,'KG','Kilogram','weight',1000) returning id into v_kg;
  insert into pack_types (org_id, code) values (v_org,'JAR') returning id into v_pack;
  insert into sections (org_id, name, sort_order) values (v_org,'RAMA KRISHNA MESTRI', 3) returning id into v_sec;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into suppliers (org_id, name) values (v_org,'SUGAR TRADERS') returning id into v_sup;

  insert into items (org_id, item_code, name, type, section_id, pack_type_id, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'2760','1/- KALAJAM(12)','finished_good', v_sec, v_pack, v_jar, 12, 1, 15, 10) returning id into v_kalajam;
  insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit, purchase_rate)
    values (v_org,'268','SUGAR','raw_material', v_kg, 1, 1, 45) returning id into v_sugar;
  insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit, purchase_rate)
    values (v_org,'900','CARTON BOX','packing_material', v_jar, 1, 1, 12) returning id into v_carton;

  -- ============================================================
  -- 1. A PURCHASE OF RAW MATERIAL REACHES THE REPORT. This is the whole
  --    complaint: the bills were fine, the report could not show them.
  -- ============================================================
  perform save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(
      jsonb_build_object('item_id', v_sugar,   'boxes', 500, 'rate', 45),
      jsonb_build_object('item_id', v_carton,  'boxes', 200, 'rate', 12),
      jsonb_build_object('item_id', v_kalajam, 'boxes', 10,  'rate', 10)));

  select * into r from closing_stock_report(v_org, current_date) where item_id = v_sugar;
  assert found, '46.1 SUGAR is not on the stock report at all';
  assert r.purchase = 500, format('46.1 SUGAR bought 500 kg, report says %s', r.purchase);
  assert r.closing = 500, format('46.1 SUGAR closing is %s, not 500', r.closing);
  assert r.item_type = 'raw_material', format('46.1 SUGAR reports as %s', r.item_type);

  select * into r from closing_stock_report(v_org, current_date) where item_id = v_carton;
  assert found, '46.2 the packing material is not on the report';
  assert r.closing = 200, format('46.2 cartons closing %s, not 200', r.closing);

  --    And the finished good is untouched by any of it.
  select * into r from closing_stock_report(v_org, current_date) where item_id = v_kalajam;
  assert r.purchase = 10, format('46.3 KALAJAM bought 10 boxes, report says %s', r.purchase);

  -- ============================================================
  -- 2. MATERIALS GROUP ON THEIR OWN, AFTER THE MESTRI SECTIONS. Dropping
  --    them into OTHERS would put sugar in among the sweets.
  -- ============================================================
  select * into r from closing_stock_report(v_org, current_date) where item_id = v_sugar;
  assert r.section_name = 'RAW MATERIAL', format('46.4 SUGAR grouped under "%s"', r.section_name);
  assert r.section_id is null, '46.4 a material was given a mestri section';
  assert r.sort_order > 999, format('46.4 materials sort at %s, before the sections', r.sort_order);

  select * into r from closing_stock_report(v_org, current_date) where item_id = v_carton;
  assert r.section_name = 'PACKING MATERIAL', format('46.5 cartons grouped under "%s"', r.section_name);

  select * into r from closing_stock_report(v_org, current_date) where item_id = v_kalajam;
  assert r.section_name = 'RAMA KRISHNA MESTRI', format('46.5 the mestri section became "%s"', r.section_name);
  assert r.section_id = v_sec, '46.5 the finished good lost its section id';

  -- ============================================================
  -- 3. A SECTION FILTER STILL MEANS MESTRI SECTIONS ONLY. Showing the sugar
  --    inside a section would make that section's sub-total wrong.
  -- ============================================================
  select count(*) into n from closing_stock_report(v_org, current_date, null, v_sec);
  assert n = 1, format('46.6 filtering to one mestri section returned %s rows, not the one finished good', n);

  -- ============================================================
  -- 4. YESTERDAY'S PURCHASE IS OPENING STOCK, NOT TODAY'S PURCHASE.
  --    "I want purchase to show in opening stock" — it does, the day after.
  -- ============================================================
  perform save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', (current_date - 1)::text),
    jsonb_build_array(jsonb_build_object('item_id', v_sugar, 'boxes', 100, 'rate', 45)));

  select * into r from closing_stock_report(v_org, current_date) where item_id = v_sugar;
  assert r.opening = 100, format('46.7 yesterday''s 100 kg opens today at %s', r.opening);
  assert r.purchase = 500, format('46.7 today''s purchase moved to %s', r.purchase);
  assert r.closing = 600, format('46.7 600 kg bought in all, report closes at %s', r.closing);

  --    And the row still reconciles left to right, materials included.
  assert r.opening + r.purchase + r.production - r.sales + r.other = r.closing,
    format('46.8 SUGAR does not add up: %s + %s + %s - %s + %s <> %s',
           r.opening, r.purchase, r.production, r.sales, r.other, r.closing);

  -- ============================================================
  -- 5. PRODUCTION CONSUMING RAW MATERIAL SHOWS AS A MOVEMENT, not as a sale
  --    and not as nothing. This is why sugar stands negative in the first
  --    place, and the shop has to be able to SEE that happening.
  -- ============================================================
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table)
  values (v_org, v_sugar, v_loc, 'production_consume', current_date, -180.5, 'manual');

  select * into r from closing_stock_report(v_org, current_date) where item_id = v_sugar;
  assert r.other = -180.5, format('46.9 the consumption reads %s in Other', r.other);
  assert r.sales = 0, '46.9 raw material consumed by production was counted as a sale';
  assert r.closing = 419.5, format('46.9 SUGAR closes at %s, not 419.5', r.closing);
  assert r.opening + r.purchase + r.production - r.sales + r.other = r.closing, '46.9 the row stopped adding up';

  -- ============================================================
  -- 6. A ZERO PACKING CANNOT REACH THE REPORT, because it cannot reach the
  --    table. This is pinned down rather than assumed: the report divides by
  --    units_per_box, and if a zero could ever be stored, every column of that
  --    product's row would come back NULL — a blank row, which reads as "no
  --    stock" rather than "no packing".
  -- ============================================================
  begin
    insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit)
      values (v_org,'999','PALM OIL','raw_material', v_kg, 0, 1) returning id into v_nopack;
    raise exception '46.10 a product was saved with a packing of zero';
  exception when check_violation then null;
  end;

  --    One kilo to a "box" is the honest packing for a raw material, and it
  --    reports in kilos.
  insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit)
    values (v_org,'999','PALM OIL','raw_material', v_kg, 1, 1) returning id into v_nopack;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table)
  values (v_org, v_nopack, v_loc, 'purchase', current_date, 75.4, 'manual');

  select * into r from closing_stock_report(v_org, current_date) where item_id = v_nopack;
  assert found, '46.10 PALM OIL is not on the report';
  assert r.closing = 75.4, format('46.10 it reads %s rather than its 75.4 kg', r.closing);
  assert r.is_negative = false, '46.10 a positive balance was reported as negative';

  -- ============================================================
  -- 7. AN INACTIVE PRODUCT IS STILL OFF THE REPORT, as before.
  -- ============================================================
  update items set is_active = false where id = v_carton;
  select count(*) into n from closing_stock_report(v_org, current_date) where item_id = v_carton;
  assert n = 0, '46.11 an inactive product came back onto the report';

  raise notice 'OK: the stock report shows what the shop buys — a purchase of raw material or packing now reaches it instead of vanishing, materials group under headings of their own after the mestri sections and never inside one, a mestri section filter still means finished goods only, yesterday''s purchase opens today while today''s stays in Purchase, raw material consumed by production reads as a movement and not as a sale, the row still reconciles left to right, a packing of zero is refused by the table so no row can come back blank, and an inactive product stays off';
end $$;

rollback;
