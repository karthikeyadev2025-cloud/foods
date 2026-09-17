-- ============================================================
-- DB acceptance test: the six screens that had no delete at all. Rolls back.
--
-- "If possible give delete option every where in portal." None of these can be
-- a plain DELETE: every one has either moved stock, moved money, or is being
-- pointed at by something that would be left hanging. So each case here checks
-- BOTH halves — that the row goes, and that whatever it moved came back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_god uuid; v_shop uuid; v_van uuid; v_cust uuid; v_item uuid;
  v_veh uuid; v_veh2 uuid; v_veh3 uuid; v_trip uuid; v_tr uuid; v_cnt uuid; v_jv uuid; v_rev uuid;
  v_chq uuid; v_cash uuid; v_mode uuid; v_inv uuid; v_msg text; n numeric;
  uid_owner uuid := gen_random_uuid();
  base_of constant text := 'boxes in base units';
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_god;
  insert into stock_locations (org_id, name) values (v_org,'Shop') returning id into v_shop;
  insert into stock_locations (org_id, name) values (v_org,'Van 1') returning id into v_van;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, is_cheque, sort_order)
    values (v_org, 'CHEQUE', 'Cheque', true, true, true, 1) returning id into v_mode;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42) returning id into v_item;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_god, 'opening', current_date, 3200, 30);   -- 100 boxes

  -- ============================================================
  -- 1. A GODOWN TRANSFER. Stock moved to the wrong godown.
  -- ============================================================
  v_tr := save_stock_transfer(
    jsonb_build_object('from_location', v_god, 'to_location', v_shop, 'txn_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 10)));
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_shop;
  assert n = 320, format('39.0 the transfer did not move 10 boxes, %s %s arrived', n, base_of);

  assert delete_document('stock_transfer', v_tr) = 'deleted', '39.1 a transfer would not delete';
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_shop;
  assert n = 0, format('39.1 the goods stayed in the Shop: %s %s', n, base_of);
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_god;
  assert n = 3200, format('39.1 the Godown did not get them back: %s %s', n, base_of);
  assert not exists (select 1 from stock_transfers where id = v_tr), '39.1 the transfer row is still there';

  --    But not once the goods have been sold from where they went.
  v_tr := save_stock_transfer(
    jsonb_build_object('from_location', v_god, 'to_location', v_shop, 'txn_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 10)));
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_shop, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 10, 'rate', 42)));
  -- Confirmed, or it is a draft that has moved nothing and proves nothing.
  perform set_invoice_status(v_inv, 'confirmed');
  begin
    perform delete_document('stock_transfer', v_tr);
    raise exception '39.2 a transfer was undone out from under the bills that used it';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%already been sold%', format('39.2 wrong reason: %s', v_msg);
    assert v_msg like '%MYSOOR%', format('39.2 does not name the product: %s', v_msg);
  end;
  perform set_invoice_status(v_inv, 'cancelled');
  assert delete_document('stock_transfer', v_tr) = 'deleted', '39.2 it would not go once the bill was cancelled';

  -- ============================================================
  -- 2. A STOCK COUNT. Opened by accident, or posted with wrong figures.
  -- ============================================================
  --    Never posted: it moved nothing, so it simply goes.
  v_cnt := open_stock_count(v_shop, current_date);
  assert delete_document('stock_count', v_cnt) = 'deleted', '39.3 an unposted count would not delete';
  assert not exists (select 1 from stock_counts where id = v_cnt), '39.3 still there';

  --    Posted: the adjustment it wrote comes back out, and the book figure
  --    returns to what it was before anybody counted.
  v_cnt := open_stock_count(v_god, current_date);
  perform update_stock_count(v_cnt, jsonb_build_array(jsonb_build_object('item_id', v_item, 'counted_boxes', 90)));
  perform post_stock_count(v_cnt);
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_god;
  assert n = 2880, format('39.4 the count did not write the shortfall down to 90 boxes: %s %s', n, base_of);

  assert delete_document('stock_count', v_cnt) = 'deleted', '39.4 a posted count would not delete';
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_god;
  assert n = 3200, format('39.4 the adjustment was left behind: %s %s', n, base_of);
  assert not exists (select 1 from stock_ledger where ref_table = 'stock_counts' and ref_id = v_cnt),
    '39.4 the adjustment rows are still in the ledger';

  -- ============================================================
  -- 3. A VAN TRIP. Raised for the wrong day.
  -- ============================================================
  insert into vehicles (org_id, vehicle_number, location_id) values (v_org, 'AP 39 TC 1234', v_van) returning id into v_veh;
  v_trip := create_trip(jsonb_build_object('vehicle_id', v_veh, 'trip_date', current_date::text));
  perform van_load(v_trip, v_god, jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 20)));
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_van;
  assert n = 640, format('39.5 the van was not loaded with 20 boxes: %s %s', n, base_of);

  --    A trip that carried a bill is the record of a day's selling.
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_van, 'invoice_date', current_date::text,
                       'trip_id', v_trip),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  begin
    perform delete_document('trip', v_trip);
    raise exception '39.6 a trip was deleted out from under its bills';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%bill%', format('39.6 wrong reason: %s', v_msg);
    assert v_msg like '%put its goods back%', format('39.6 does not say what to do: %s', v_msg);
  end;

  perform set_invoice_status(v_inv, 'cancelled');
  assert delete_document('trip', v_trip) = 'deleted', '39.6 it would not go once the bill was cancelled';
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_van;
  assert n = 0, format('39.6 the goods were left on a van that no longer exists: %s %s', n, base_of);
  select coalesce(sum(qty_base), 0) into n from stock_ledger where item_id = v_item and location_id = v_god;
  assert n = 3200, format('39.6 the godown did not get the load back: %s %s', n, base_of);

  -- ============================================================
  -- 4. A VEHICLE. Entered twice.
  -- ============================================================
  insert into vehicles (org_id, vehicle_number, location_id) values (v_org, 'AP 39 TC 9999', v_van) returning id into v_veh2;
  assert delete_master('vehicle', v_veh2) = 'deleted', '39.7 an unused vehicle would not delete';
  assert not exists (select 1 from vehicles where id = v_veh2), '39.7 still there';

  --    One that is out on a trip is held by it, and goes once the trip has.
  insert into vehicles (org_id, vehicle_number, location_id) values (v_org, 'AP 39 TC 4444', v_van) returning id into v_veh3;
  v_trip := create_trip(jsonb_build_object('vehicle_id', v_veh3, 'trip_date', current_date::text));
  begin
    perform delete_master('vehicle', v_veh3);
    raise exception '39.8 a vehicle out on a trip was deleted';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%trip%', format('39.8 wrong reason: %s', v_msg);
    assert v_msg like '%inactive%', format('39.8 does not offer the way out: %s', v_msg);
  end;
  perform delete_document('trip', v_trip);
  assert delete_master('vehicle', v_veh3) = 'deleted', '39.8 it would not go once the trip had been removed';

  --    A CANCELLED bill still names the van it went out on, and still holds it.
  --    This is the van from the trip above: the trip is gone, the bill was
  --    cancelled, and the record of which vehicle carried it is the whole point
  --    of keeping a cancelled bill on the list at all.
  assert exists (select 1 from invoices where vehicle_id = v_veh and status = 'cancelled'),
    '39.9 the test no longer has a cancelled bill against that van';
  begin
    perform delete_master('vehicle', v_veh);
    raise exception '39.9 a vehicle named on a bill was deleted because the bill was cancelled';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%bill%', format('39.9 wrong reason: %s', v_msg);
  end;

  -- ============================================================
  -- 5. A HAND-TYPED LEDGER ENTRY, with the figures the wrong way round.
  -- ============================================================
  perform ensure_default_accounts(v_org);   -- made on first use; nothing has moved money yet
  select id into v_cash from cash_bank_accounts where org_id = v_org and kind = 'cash' limit 1;
  assert v_cash is not null, '39.10 no cash account to post through';

  v_jv := save_manual_journal(jsonb_build_object(
    'entry_date', current_date::text, 'narration', 'Typed the wrong way round',
    'lines', jsonb_build_array(
      jsonb_build_object('code', 'CASH', 'debit', 500, 'cash_account_id', v_cash),
      jsonb_build_object('code', 'SALES', 'credit', 500))));
  select count(*) into n from account_transactions where ref_table = 'journal_entries' and ref_id = v_jv;
  assert n = 1, format('39.10 the entry did not move money through the cash book (%s rows)', n);

  --    An entry raised by a bill is that document's own record of itself.
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_god, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');   -- a draft raises no ledger entry
  begin
    perform delete_document('journal',
      (select id from journal_entries where org_id = v_org and ref_table = 'invoices' and ref_id = v_inv));
    raise exception '39.11 a bill''s own ledger entry was deleted behind its back';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%invoice%', format('39.11 does not name what raised it: %s', v_msg);
    assert v_msg like '%Delete that document%', format('39.11 does not say what to do: %s', v_msg);
  end;

  --    Reversed already: the pair comes apart in the order it was made.
  v_rev := reverse_manual_journal(v_jv);
  begin
    perform delete_document('journal', v_jv);
    raise exception '39.12 an entry was deleted while its reversal still stood';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%already been reversed%', format('39.12 wrong reason: %s', v_msg);
    assert v_msg like '%Delete that reversal first%', format('39.12 does not say what to do: %s', v_msg);
  end;

  assert delete_document('journal', v_rev) = 'deleted', '39.12 the reversal would not delete';
  assert delete_document('journal', v_jv) = 'deleted', '39.12 the entry would not delete once the reversal had gone';
  --    And the money it moved is not still sitting in the cash book.
  select count(*) into n from account_transactions where ref_table = 'journal_entries' and ref_id = v_jv;
  assert n = 0, format('39.12 the cash book kept %s row(s) for an entry that no longer exists', n);
  assert not exists (select 1 from journal_lines where entry_id = v_jv), '39.12 the lines were left behind';

  -- ============================================================
  -- 6. A CHEQUE, with the number keyed in wrong.
  -- ============================================================
  insert into cheques (org_id, direction, party_kind, customer_id, cheque_no, cheque_date, bank_name, amount, state, account_id)
  values (v_org, 'received', 'customer', v_cust, '000123', current_date, 'SBI', 5000, 'in_hand', v_cash)
  returning id into v_chq;

  assert delete_document('cheque', v_chq) = 'deleted', '39.13 a hand-entered cheque would not delete';
  assert not exists (select 1 from cheques where id = v_chq), '39.13 still there';

  --    One taken on a receipt belongs to that receipt.
  perform save_receipt(
    jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date::text),
    jsonb_build_array(jsonb_build_object('mode_id', v_mode, 'amount', 100, 'reference', '000999',
                                         'cheque_date', current_date::text, 'bank_name', 'SBI')));
  select id into v_chq from cheques where org_id = v_org and cheque_no = '000999';
  -- Asserted, not skipped: an `if v_chq is not null` here would let the whole
  -- case pass on a day the receipt stopped raising a cheque at all.
  assert v_chq is not null, '39.14 the receipt did not raise a cheque, so this proves nothing';
  begin
    perform delete_document('cheque', v_chq);
    raise exception '39.14 a cheque was taken off a receipt behind its back';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%receipt%', format('39.14 does not name what it came in on: %s', v_msg);
  end;
  assert exists (select 1 from cheques where id = v_chq), '39.14 it was removed anyway';

  -- ============================================================
  -- 7. Something that is not one of ours still says so.
  -- ============================================================
  begin
    perform delete_document('haystack', gen_random_uuid());
    raise exception '39.15 an unknown kind was accepted';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%Unknown document type%', format('39.15 wrong reason: %s', v_msg);
  end;

  raise notice 'OK: delete on the last six screens — a godown transfer, a stock count, a van trip, a vehicle, a hand-typed ledger entry and a cheque all delete and put back exactly what they moved; each is refused by name when a bill, a receipt, a trip or a reversal is still standing on it; and the stock and the cash book are left as though none of it had happened';
end $$;

rollback;
