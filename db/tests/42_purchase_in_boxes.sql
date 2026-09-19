-- ============================================================
-- DB acceptance test: a purchase is typed in boxes, like a bill. Rolls back.
--
-- The shop's own figure is the test. 1/- KALAJAM(12) is twelve jars to a box.
-- Somebody bought boxes and the stock report showed 4.25 of them, because the
-- screen had handed the quantity to the item's BASE unit — so the number meant
-- jars. Fifty-one jars is 4.25 boxes.
--
-- 4.25 is therefore the number this test must stop producing.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_kg uuid; v_loc uuid; v_sup uuid; v_sup2 uuid;
  v_kalajam uuid; v_sugar uuid; v_pur uuid; v_old uuid;
  r record; n numeric; v_rate numeric; v_msg text;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into uoms (org_id, code, name, basis, weight_g) values (v_org,'KG','Kilogram','weight',1000) returning id into v_kg;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into suppliers (org_id, name) values (v_org,'SUGAR TRADERS') returning id into v_sup;
  insert into suppliers (org_id, name) values (v_org,'OTHER TRADERS') returning id into v_sup2;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'2760','1/- KALAJAM(12)', v_jar, 12, 1, 15, 10) returning id into v_kalajam;
  insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit, purchase_rate)
    values (v_org,'RM-SUGAR','SUGAR','raw_material', v_kg, 1, 1, 45) returning id into v_sugar;

  -- ============================================================
  -- 1. THE SHOP'S NUMBER. Fifty-one boxes is fifty-one boxes.
  -- ============================================================
  v_pur := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text, 'bill_no', 'S-1'),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 51, 'rate', 10)));

  select boxes, qty, qty_base, amount into r from purchase_items where purchase_id = v_pur;
  assert r.boxes = 51, format('42.1 saved %s boxes', r.boxes);
  assert r.qty = 612, format('42.1 fifty-one boxes of twelve is 612 jars, got %s', r.qty);
  assert r.qty_base = 612, format('42.1 base quantity %s', r.qty_base);
  assert r.boxes <> 4.25, '42.1 the original fault is back';

  --    And the godown holds fifty-one boxes, not four and a quarter.
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_kalajam;
  assert n = 612, format('42.2 the godown received %s jars, not 612', n);
  assert n / 12 = 51, format('42.2 which is %s boxes, not 51', n / 12);

  --    The money follows the same quantity: 612 jars at 10 is 6,120.
  assert r.amount = 6120, format('42.3 line amount %s', r.amount);
  select subtotal, total into r from purchases where id = v_pur;
  assert r.subtotal = 6120 and r.total = 6120, format('42.3 subtotal %s, total %s', r.subtotal, r.total);

  -- ============================================================
  -- 2. THE HEADER AND THE LINES CANNOT DISAGREE. The subtotal is added up from
  --    the rows that were saved, not from what the caller sent — the old code
  --    totalled the incoming qty, so the two did their own arithmetic and only
  --    agreed while both used the same units.
  -- ============================================================
  v_pur := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text, 'other_charges', 100),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 2, 'rate', 10),
                      jsonb_build_object('item_id', v_sugar, 'boxes', 30, 'rate', 45)));
  select coalesce(sum(amount), 0) into n from purchase_items where purchase_id = v_pur;
  select subtotal, total into r from purchases where id = v_pur;
  assert r.subtotal = n, format('42.4 header says %s, the lines add to %s', r.subtotal, n);
  assert r.total = n + 100, format('42.4 total %s does not carry the 100 other charges', r.total);

  --    A one-to-a-box raw material is unchanged by any of this: 30 KG is 30 KG.
  select boxes, qty into r from purchase_items where purchase_id = v_pur and item_id = v_sugar;
  assert r.boxes = 30 and r.qty = 30, format('42.5 raw material became %s boxes / %s', r.boxes, r.qty);

  -- ============================================================
  -- 3. A CALLER THAT STILL SENDS A BARE QTY KEEPS WORKING, and the boxes are
  --    worked back out of it. The importer and any older client go this way.
  -- ============================================================
  v_old := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'qty', 612, 'uom_id', v_jar, 'rate', 10)));
  select boxes, qty, amount into r from purchase_items where purchase_id = v_old;
  assert r.qty = 612, format('42.6 a bare qty was changed to %s', r.qty);
  assert r.boxes = 51, format('42.6 612 jars is 51 boxes, recorded as %s', r.boxes);
  assert r.amount = 6120, format('42.6 amount %s', r.amount);

  -- ============================================================
  -- 4. THE PACKING CANNOT MOVE UNDER AN ENTERED PURCHASE.
  --
  --    Two defences, and the outer one turns out to be the stronger: once a
  --    product has any stock movement the database refuses to re-pack it at
  --    all. Asserted here rather than assumed, because the whole boxes model
  --    rests on it — if re-packing were ever allowed, every purchase and bill
  --    already entered would silently mean a different quantity.
  -- ============================================================
  begin
    update items set units_per_box = 24 where id = v_kalajam;
    raise exception '42.7 a product with stock behind it was re-packed';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%Packing is locked%', format('42.7 wrong reason: %s', v_msg);
  end;
  select boxes, qty, units_per_box into r from purchase_items where purchase_id = v_pur and item_id = v_kalajam;
  assert r.qty = 24 and r.boxes = 2 and r.units_per_box = 12,
    format('42.7 the line reads %s boxes x %s = %s', r.boxes, r.units_per_box, r.qty);

  --    And the line carries its own copy of the packing, so it would still read
  --    correctly even if the master ever did move.
  assert r.units_per_box = 12, '42.7 the line did not snapshot its packing';

  -- ============================================================
  -- 5. NOTHING AT ALL IS STILL REFUSED, by either name.
  -- ============================================================
  begin
    perform save_purchase(
      jsonb_build_object('location_id', v_loc, 'bill_date', current_date::text),
      jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 0, 'rate', 10)));
    raise exception '42.8 a line of nought boxes was accepted';
  exception when sqlstate 'P0001' then null;
  end;

  -- ============================================================
  -- 6. WHAT THIS SUPPLIER LAST CHARGED — the buying side of the bill screen's
  --    rate history, asked for in the same sentence.
  -- ============================================================
  v_pur := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', (current_date - 3)::text, 'bill_no', 'S-9'),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 5, 'rate', 99)));

  select * into r from supplier_last_rates(v_sup) where item_id = v_kalajam;
  assert r.rate = 10, format('42.9 came back with %s, not the 10 charged today', r.rate);
  assert r.bill_date = current_date, format('42.9 dated %s', r.bill_date);
  assert r.times_bought = 4, format('42.9 counted %s purchases of it', r.times_bought);

  --    And another supplier's rate is not this one's.
  v_pur := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup2, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 1, 'rate', 77)));
  select rate into v_rate from supplier_last_rates(v_sup) where item_id = v_kalajam;
  assert v_rate = 10, format('42.10 another supplier''s %s leaked across', v_rate);
  select rate into v_rate from supplier_last_rates(v_sup2) where item_id = v_kalajam;
  assert v_rate = 77, format('42.10 the other supplier got %s', v_rate);

  --    And another shop sees none of it.
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  select count(*) into n from supplier_last_rates(v_sup);
  assert n = 0, format('42.11 a stranger read %s of this shop''s buying rates', n);

  raise notice 'OK: a purchase is typed in boxes — 51 boxes of a twelve-pack is 612 jars in the godown and 6,120 on the bill, never the 4.25 boxes the old screen produced; the header total is added from the saved rows so it cannot disagree with them; a bare qty from the importer still works and has its boxes worked back out; the packing is snapshotted so re-packing a product never re-quantifies a purchase already entered; and supplier_last_rates gives the buying side of the bill screen''s rate history without leaking across suppliers or shops';
end $$;

rollback;
