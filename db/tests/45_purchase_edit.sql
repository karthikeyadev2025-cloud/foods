-- ============================================================
-- DB acceptance test: editing a purchase. Rolls back.
--
-- The thing that can go badly wrong here is stock arithmetic. An edit that
-- posts without taking the old bill back doubles the godown; one that takes it
-- back twice empties it. Both look fine on the screen that did the edit and are
-- only found weeks later, when a stock report will not tally. So most of this
-- test is counting jars.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_loc uuid; v_loc2 uuid; v_cust uuid; v_sup uuid; v_sup2 uuid;
  v_kalajam uuid; v_chekodi uuid; v_sugar uuid;
  v_pur uuid; v_pur2 uuid; v_inv uuid; v_msg text; v_no text; n bigint; v_bal numeric;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into stock_locations (org_id, name) values (v_org,'Godown 2') returning id into v_loc2;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into suppliers (org_id, name) values (v_org,'SUGAR TRADERS') returning id into v_sup;
  insert into suppliers (org_id, name) values (v_org,'BALAJI AGENCIES') returning id into v_sup2;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'2760','1/- KALAJAM(12)', v_jar, 12, 1, 15, 10) returning id into v_kalajam;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'100','5/- CHEKODI (38) 6', v_jar, 6, 1, 30, 22) returning id into v_chekodi;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'268','SUGAR', v_jar, 1, 1, 0, 45) returning id into v_sugar;

  -- ============================================================
  -- 1. A BILL TYPED WRONG. Ten boxes at ten rupees, and the rate was
  --    really twelve.
  -- ============================================================
  v_pur := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 10, 'rate', 10)));

  select bill_no into v_no from purchases where id = v_pur;
  select coalesce(sum(qty_base),0) into v_bal from stock_ledger where item_id = v_kalajam and location_id = v_loc;
  assert v_bal = 120, format('45.1 ten boxes of twelve came to %s jars', v_bal);
  assert (select total from purchases where id = v_pur) = 1200, '45.1 wrong total before the edit';

  -- The correction: same ten boxes, right rate.
  perform save_purchase(
    jsonb_build_object('id', v_pur, 'location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 10, 'rate', 12)));

  --    THE WHOLE POINT: the shelf still holds ten boxes, not twenty and not none.
  select coalesce(sum(qty_base),0) into v_bal from stock_ledger where item_id = v_kalajam and location_id = v_loc;
  assert v_bal = 120, format('45.2 after the edit the godown holds %s jars, not 120', v_bal);
  assert (select total from purchases where id = v_pur) = 1440, '45.2 the corrected total did not save';

  --    It is the same bill, with the same number. A second number would mean
  --    two bills for one delivery.
  select count(*) into n from purchases where org_id = v_org;
  assert n = 1, format('45.3 the edit left %s purchases', n);
  assert (select bill_no from purchases where id = v_pur) = v_no, '45.3 the edit took a fresh bill number';

  --    And the ledger shows all three movements, not a rewritten one.
  select count(*) into n from stock_ledger where ref_table = 'purchases' and ref_id = v_pur;
  assert n = 3, format('45.4 %s stock rows; the correction should ADD rows, never delete them', n);

  --    The money is corrected the same way — by a reversing entry, leaving a trail.
  assert exists (select 1 from journal_entries where ref_table='purchases' and ref_id=v_pur and reverses_entry_id is not null),
    '45.4 no reversing entry for the corrected bill';
  select coalesce(sum(jl.debit - jl.credit), 0) into v_bal
    from journal_lines jl
    join journal_entries je on je.id = jl.entry_id
    join ledger_accounts la on la.id = jl.account_id
   where je.ref_table = 'purchases' and je.ref_id = v_pur and la.code = 'PURCHASES';
  assert v_bal = 1440, format('45.5 the purchases account carries %s, not the corrected 1440', v_bal);

  -- ============================================================
  -- 2. EVERY PART OF THE HEADER IS CORRECTABLE — including the godown,
  --    which has to move the goods with it.
  -- ============================================================
  perform save_purchase(
    jsonb_build_object('id', v_pur, 'location_id', v_loc2, 'supplier_id', v_sup2,
                       'bill_date', (current_date - 3)::text, 'other_charges', 50, 'notes', 'lorry freight'),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 10, 'rate', 12)));

  select coalesce(sum(qty_base),0) into v_bal from stock_ledger where item_id = v_kalajam and location_id = v_loc;
  assert v_bal = 0, format('45.6 the first godown kept %s jars after the goods moved', v_bal);
  select coalesce(sum(qty_base),0) into v_bal from stock_ledger where item_id = v_kalajam and location_id = v_loc2;
  assert v_bal = 120, format('45.6 the second godown holds %s jars, not 120', v_bal);
  assert (select supplier_id from purchases where id = v_pur) = v_sup2, '45.6 the supplier did not change';
  assert (select total from purchases where id = v_pur) = 1490, '45.6 other charges did not reach the total';

  -- ============================================================
  -- 3. LINES ADDED AND TAKEN OFF.
  -- ============================================================
  perform save_purchase(
    jsonb_build_object('id', v_pur, 'location_id', v_loc2, 'supplier_id', v_sup2, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_chekodi, 'boxes', 4, 'rate', 20)));

  select coalesce(sum(qty_base),0) into v_bal from stock_ledger where item_id = v_kalajam;
  assert v_bal = 0, format('45.7 a line taken off the bill left %s jars behind', v_bal);
  select coalesce(sum(qty_base),0) into v_bal from stock_ledger where item_id = v_chekodi and location_id = v_loc2;
  assert v_bal = 24, format('45.7 four boxes of six came to %s jars', v_bal);
  select count(*) into n from purchase_items where purchase_id = v_pur;
  assert n = 1, format('45.7 %s lines on the bill, not one', n);

  -- ============================================================
  -- 4. IT REFUSES TO TAKE BACK GOODS THAT HAVE BEEN SOLD ON. The
  --    shop would be left with less than nothing on the shelf.
  -- ============================================================
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc2, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_chekodi, 'boxes', 4, 'rate', 30)));
  perform set_invoice_status(v_inv, 'confirmed');

  begin
    perform save_purchase(
      jsonb_build_object('id', v_pur, 'location_id', v_loc2, 'supplier_id', v_sup2, 'bill_date', current_date::text),
      jsonb_build_array(jsonb_build_object('item_id', v_chekodi, 'boxes', 1, 'rate', 20)));
    raise exception '45.8 a purchase was cut below what had already been sold';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%CHEKODI%', format('45.8 does not name the product: %s', v_msg);
  end;

  --    And the refusal put everything back — the bill, the stock and the money.
  select coalesce(sum(qty_base),0) into v_bal from stock_ledger where item_id = v_chekodi and location_id = v_loc2;
  assert v_bal = 0, format('45.9 after the refusal the shelf reads %s, not 24 in less 24 out', v_bal);
  select coalesce(sum(qty_base),0) into v_bal
    from stock_ledger where ref_table = 'purchases' and ref_id = v_pur and item_id = v_chekodi;
  assert v_bal = 24, format('45.9 the refused edit left the bill holding %s jars, not 24', v_bal);
  assert (select boxes from purchase_items where purchase_id = v_pur) = 4, '45.9 the refused edit saved its lines anyway';

  --    Raising the quantity is fine — nothing goes below anything.
  perform save_purchase(
    jsonb_build_object('id', v_pur, 'location_id', v_loc2, 'supplier_id', v_sup2, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_chekodi, 'boxes', 9, 'rate', 20)));
  select coalesce(sum(qty_base),0) into v_bal from stock_ledger where item_id = v_chekodi and location_id = v_loc2;
  assert v_bal = 30, format('45.10 nine boxes in, four sold, leaves %s jars not 30', v_bal);

  -- ============================================================
  -- 5. A PRODUCT ALREADY STANDING NEGATIVE is still correctable. The
  --    shop has raw material consumed by production that was never
  --    entered as bought — SUGAR at minus 180 kg. Refusing to let them
  --    fix the bills for it would be the opposite of helpful.
  -- ============================================================
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table)
  values (v_org, v_sugar, v_loc, 'production_consume', current_date, -180.5, 'manual');

  v_pur2 := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_sugar, 'boxes', 50, 'rate', 45)));

  --    Correcting 50 down to 40 leaves it deeper in the red, and is allowed:
  --    the bill is what is wrong, not the shop.
  perform save_purchase(
    jsonb_build_object('id', v_pur2, 'location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_sugar, 'boxes', 40, 'rate', 45)));
  select coalesce(sum(qty_base),0) into v_bal from stock_ledger where item_id = v_sugar;
  assert v_bal = -140.5, format('45.11 sugar reads %s, not -140.5', v_bal);

  -- ============================================================
  -- 6. A BILL WITH A RETURN AGAINST IT IS NOT EDITABLE. The return
  --    was worked out from these quantities.
  -- ============================================================
  insert into purchase_returns (org_id, return_no, purchase_id, supplier_id, return_date)
  values (v_org, 'PR-1', v_pur2, v_sup, current_date);
  begin
    perform save_purchase(
      jsonb_build_object('id', v_pur2, 'location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
      jsonb_build_array(jsonb_build_object('item_id', v_sugar, 'boxes', 30, 'rate', 45)));
    raise exception '45.12 a purchase with a return against it was edited';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%return%', format('45.12 wrong reason: %s', v_msg);
  end;

  -- ============================================================
  -- 7. SOMEBODY ELSE'S BILL IS NOT FOUND, not edited.
  -- ============================================================
  begin
    perform save_purchase(
      jsonb_build_object('id', gen_random_uuid(), 'location_id', v_loc, 'bill_date', current_date::text),
      jsonb_build_array(jsonb_build_object('item_id', v_sugar, 'boxes', 1, 'rate', 45)));
    raise exception '45.13 an unknown purchase id was accepted';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%not found%', format('45.13 wrong reason: %s', v_msg);
  end;

  raise notice 'OK: a purchase can be corrected — rate, date, supplier, godown and lines — and the godown holds exactly what the corrected bill says, because the old posting is REVERSED with opposite rows rather than deleted; the bill keeps its number and its trail, the money is corrected by a reversing journal entry; an edit that would take back goods already sold on is refused and rolls back whole, while a product already standing negative is still correctable; a bill with a return against it, and a bill belonging to nobody, are both refused';
end $$;

rollback;
