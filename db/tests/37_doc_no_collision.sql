-- ============================================================
-- DB acceptance test: a document number that is already taken. Rolls back.
--
-- Reproduces the till failure first — walk the counter back over bills that
-- exist, the way Setup → Numbering or a period reset does — and only then
-- checks the fix. A test that cannot produce the original 23505 proves nothing
-- about having cured it.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_item uuid;
  v_inv uuid; v_no text; n bigint; r record;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42) returning id into v_item;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 100000, 30);

  -- Three bills, so 0001..0003 are spoken for.
  for n in 1..3 loop
    perform save_invoice(
      jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  end loop;
  select count(*) into n from invoices where org_id = v_org;
  assert n = 3, format('37.0 expected 3 bills, got %s', n);
  assert exists (select 1 from invoices where org_id = v_org and invoice_no = '0001'), '37.0 numbering is not what this test assumes';

  -- 1. THE FAILURE FROM THE TILL. Somebody sets the counter back — by typing it
  --    in Setup → Numbering, or by a monthly reset on a series whose prefix
  --    carries no month. The next bill lands on 0001, which exists.
  update number_series set next_number = 1 where org_id = v_org and doc_type = 'invoice';

  v_no := next_doc_no(v_org, 'invoice');
  assert v_no = '0004', format('37.1 handed back "%s", which is already on a bill', v_no);

  -- And the counter is left PAST it, so the bill after that is 0005 rather than
  -- walking the same ground again.
  assert (select next_number from number_series where org_id = v_org and doc_type = 'invoice') = 5,
    '37.1 the counter was not left past the number it gave out';

  -- 2. End to end: the save that used to fail now goes through.
  update number_series set next_number = 1 where org_id = v_org and doc_type = 'invoice';
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  assert (select invoice_no from invoices where id = v_inv) = '0004',
    format('37.2 saved as %s', (select invoice_no from invoices where id = v_inv));

  -- 3. A gap in the middle is used, not skipped: numbering stays tight.
  delete from invoice_items where invoice_id in (select id from invoices where org_id = v_org and invoice_no = '0002');
  delete from stock_ledger where org_id = v_org and ref_table = 'invoices'
     and ref_id in (select id from invoices where org_id = v_org and invoice_no = '0002');
  delete from invoices where org_id = v_org and invoice_no = '0002';
  update number_series set next_number = 1 where org_id = v_org and doc_type = 'invoice';
  assert next_doc_no(v_org, 'invoice') = '0002', '37.3 a free number in the middle was skipped over';

  -- 4. resync_doc_numbers() moves a stranded counter in one step.
  update number_series set next_number = 1 where org_id = v_org and doc_type = 'invoice';
  select count(*) into n from resync_doc_numbers() where doc_type = 'invoice';
  assert n = 1, '37.4 resync did not report the invoice series';
  -- 0001, 0003 and 0004 exist (0002 was deleted), so the counter belongs at 5.
  assert (select next_number from number_series where org_id = v_org and doc_type = 'invoice') = 5,
    format('37.4 counter left at %s',
      (select next_number from number_series where org_id = v_org and doc_type = 'invoice'));

  -- Run twice and the second says there was nothing to do.
  select count(*) into n from resync_doc_numbers();
  assert n = 0, format('37.5 a second resync moved %s series that were already right', n);

  -- 5. A series with nowhere to look keeps the old behaviour rather than
  --    guessing at a table that may not exist.
  insert into number_series (org_id, doc_type, next_number) values (v_org, 'barcode', 7);
  assert next_doc_no(v_org, 'barcode') = '0007', '37.6 an unmapped doc type stopped working';

  -- 6. A prefix is respected: 'INV-' numbers are checked against 'INV-' bills.
  update number_series set prefix = 'INV-', next_number = 1 where org_id = v_org and doc_type = 'invoice';
  -- The plain 0001 must NOT block INV-0001; they are different numbers.
  assert next_doc_no(v_org, 'invoice') = 'INV-0001',
    format('37.7 a prefixed series was blocked by an unprefixed bill: %s', next_doc_no(v_org, 'invoice'));

  raise notice 'OK: document numbering — a number already on a bill is never handed out again, the counter is left past whatever it gave, a genuine gap in the middle is still filled, an unmapped doc type is untouched, a prefix is respected, and resync_doc_numbers() moves a stranded counter in one step and reports nothing the second time';
end $$;

rollback;
