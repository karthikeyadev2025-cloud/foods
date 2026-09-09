-- ============================================================
-- DB acceptance test: automatic purchase numbers. Rolls back.
--
-- A purchase entered without the supplier's bill number had no number at all —
-- nothing to search for, nothing on the journal narration. It now takes the
-- next number from its own series, while a real supplier number is still kept
-- exactly as typed.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_sup uuid; v_item uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid; v_a text; v_b text; v_c text; v_narr text;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis, weight_g) values (v_org, 'KG', 'Kilogram', 'weight', 1000) returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into suppliers (org_id, name) values (v_org, 'SUGAR TRADERS') returning id into v_sup;
  insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit, purchase_rate)
    values (v_org, 'RM1', 'SUGAR', 'raw_material', v_uom, 1, 1, 45) returning id into v_item;

  -- 1. No bill number on the mandi slip: the purchase still gets a number.
  v_p1 := save_purchase(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 100, 'uom_id', v_uom, 'rate', 45)));
  select bill_no into v_a from purchases where id = v_p1;
  assert v_a is not null and v_a <> '', '25.1 a blank bill number left the purchase unnumbered';

  -- 2. The next one is different — a series, not a constant.
  v_p2 := save_purchase(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 50, 'uom_id', v_uom, 'rate', 45)));
  select bill_no into v_b from purchases where id = v_p2;
  assert v_b <> v_a, format('25.2 two purchases share the number %s', v_a);

  -- 3. A supplier who DOES print a number keeps theirs, untouched. This is the
  --    half that must not be automated away: it is what matches our books to
  --    theirs when a payment is disputed.
  v_p3 := save_purchase(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', current_date::text, 'bill_no', 'ST/2026/8841'),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 25, 'uom_id', v_uom, 'rate', 45)));
  assert (select bill_no from purchases where id = v_p3) = 'ST/2026/8841',
    format('25.3 the supplier number was replaced: %s', (select bill_no from purchases where id = v_p3));

  -- 4. Whitespace is not a bill number — it falls through to the series, and
  --    the number it gets is a different one again.
  v_p4 := save_purchase(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_no', '   '),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'uom_id', v_uom, 'rate', 45)));
  select bill_no into v_c from purchases where id = v_p4;
  assert trim(v_c) = v_c and v_c <> '', format('25.4 spaces were stored as a bill number: "%s"', v_c);
  assert v_c not in (v_a, v_b), format('25.4 reused an earlier number: %s', v_c);

  -- 5. The automatic number reaches the ledger. The narration used to read the
  --    caller's header, so it would have said "Purchase  — SUGAR TRADERS".
  select je.narration into v_narr from journal_entries je where je.ref_table = 'purchases' and je.ref_id = v_p1;
  assert v_narr like '%' || v_a || '%', format('25.5 the ledger did not get the number: %s', v_narr);

  raise notice 'OK: purchase numbering — a purchase with no supplier bill number takes the next number from its own series and carries it to the ledger, a printed supplier number is kept exactly as typed, and blank means blank rather than a row of spaces';
end $$;

rollback;
