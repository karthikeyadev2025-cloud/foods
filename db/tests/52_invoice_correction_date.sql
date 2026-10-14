-- ============================================================
-- DB acceptance test: correcting a bill must not change any earlier day.
--
-- "stock check now lot of minus opening why". A bill of 10 boxes on the 8th,
-- corrected on the 14th, used to read as 20 boxes gone on every day in
-- between, because the goods went out on the BILL's date and came back on
-- TODAY's. Today was always right, so it hid in the opening column.
--
-- Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_loc uuid; v_cust uuid; v_item uuid;
  v_inv uuid; v_inv2 uuid; r record; q numeric; n int;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');

  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','5/- HT. MYSOOR PAK(12) 32', v_jar, 32, 1, 42) returning id into v_item;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base)
    values (v_org, v_item, v_loc, 'opening', current_date - 10, 3200);   -- 100 boxes

  -- a bill for 10 boxes, six days ago
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', (current_date - 6)::text, 'location_id', v_loc),
                        jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 10, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');

  select closing into r from closing_stock_report(v_org, current_date - 3, v_loc) where item_id = v_item;
  assert r.closing = 90, format('52.1 as at three days ago the godown holds 90 boxes, holds %s', r.closing);

  -- ===== 52.2 corrected today to the SAME figures: no day may move =====
  perform reopen_invoice(v_inv);
  perform set_invoice_status(v_inv, 'confirmed');

  select closing into r from closing_stock_report(v_org, current_date - 3, v_loc) where item_id = v_item;
  assert r.closing = 90, format('52.2 correcting a bill today changed what the godown held three days ago: %s boxes', r.closing);
  select opening into r from closing_stock_report(v_org, current_date, v_loc) where item_id = v_item;
  assert r.opening = 90, format('52.2 the opening column should be 90 boxes, is %s', r.opening);
  select closing into r from closing_stock_report(v_org, current_date, v_loc) where item_id = v_item;
  assert r.closing = 90, format('52.2 today should still be 90 boxes, is %s', r.closing);

  -- every row of the bill sits on the bill's own date
  assert not exists (select 1 from stock_ledger
                      where ref_table = 'invoices' and ref_id = v_inv and txn_date <> current_date - 6),
    '52.2 a row of the corrected bill is dated away from the bill';

  -- ===== 52.3 a real correction moves the day it is for, and only that day =====
  perform reopen_invoice(v_inv);
  perform save_invoice(jsonb_build_object('id', v_inv, 'customer_id', v_cust, 'invoice_date', (current_date - 6)::text, 'location_id', v_loc),
                       jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 15, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');

  select closing into r from closing_stock_report(v_org, current_date - 3, v_loc) where item_id = v_item;
  assert r.closing = 85, format('52.3 after correcting 10 boxes to 15, three days ago should read 85, reads %s', r.closing);
  select closing into r from closing_stock_report(v_org, current_date - 8, v_loc) where item_id = v_item;
  assert r.closing = 100, format('52.3 the day before the bill must still read 100, reads %s', r.closing);

  -- ===== 52.4 a cancelled bill is void from its own date =====
  v_inv2 := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', (current_date - 5)::text, 'location_id', v_loc),
                         jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 4, 'rate', 42)));
  perform set_invoice_status(v_inv2, 'confirmed');
  select closing into r from closing_stock_report(v_org, current_date - 3, v_loc) where item_id = v_item;
  assert r.closing = 85 - 4, format('52.4 with the second bill, three days ago reads %s', r.closing);

  perform set_invoice_status(v_inv2, 'cancelled');
  select closing into r from closing_stock_report(v_org, current_date - 3, v_loc) where item_id = v_item;
  assert r.closing = 85, format('52.4 a cancelled bill must leave no dent on an earlier day; reads %s', r.closing);
  select coalesce(sum(qty_base), 0) into q from stock_ledger where ref_table = 'invoices' and ref_id = v_inv2;
  assert q = 0, format('52.4 a cancelled bill must hold no stock, holds %s', q);

  -- ===== 52.5 the money follows the same date =====
  -- the cancelled bill must not sit in a sales figure for the day it was for
  select coalesce(sum(jl.credit) - sum(jl.debit), 0) into q
    from journal_lines jl
    join journal_entries je on je.id = jl.entry_id
    join ledger_accounts la on la.id = jl.account_id
   where je.ref_table = 'invoices' and je.ref_id = v_inv2 and la.code = 'SALES';
  assert q = 0, format('52.5 the cancelled bill still shows %s of sales', q);
  assert not exists (select 1 from journal_entries
                      where ref_table = 'invoices' and ref_id = v_inv2 and entry_date <> current_date - 5),
    '52.5 a journal entry of the cancelled bill is dated away from the bill';
  assert trial_balance_check(v_org) = 0, '52.5 the books must still balance';

  raise notice 'OK: correcting a bill no longer changes what the godown held on any earlier day — the goods come back on the BILL''s date rather than today, so the pair cancels where it was made; a real correction moves only the day it is for, the day before it is untouched, a cancelled bill is void from its own date and holds no stock and no sales, and the books still balance';
end $$;

rollback;
