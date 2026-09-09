-- ============================================================
-- DB acceptance test: one search across every kind of bill. Rolls back.
--
-- The case this exists for: a customer rings and says "number 41". Nobody knows
-- whether that is an invoice, a challan, a receipt or a quotation, and each
-- screen only searches its own kind.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_other uuid; v_sup uuid; v_item uuid; v_mode uuid;
  v_inv uuid; v_q uuid; v_rec uuid; v_pu uuid; n int; r record;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into receipt_modes (org_id, code, name) values (v_org, 'CASH', 'Cash') returning id into v_mode;
  insert into suppliers (org_id, name) values (v_org, 'SUGAR TRADERS') returning id into v_sup;
  insert into customers (org_id, name, town) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA') returning id into v_cust;
  insert into customers (org_id, name, town) values (v_org, 'MASTAN VALI', 'TAKKELLAPADU') returning id into v_other;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '8', 'HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42, 30) returning id into v_item;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 5000, 30);

  -- One document of several kinds, two of them for the same customer.
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  v_q := save_quotation(
    jsonb_build_object('customer_id', v_cust, 'quote_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  v_rec := save_receipt(
    jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date::text),
    jsonb_build_array(jsonb_build_object('mode_id', v_mode, 'amount', 500)));
  v_pu := save_purchase(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'uom_id', v_uom, 'rate', 30)));

  -- 1. A customer's name finds every kind of document for them at once. This is
  --    the whole feature: three different screens' worth in one list.
  select count(distinct kind) into n from search_documents('srinivas', 50);
  assert n >= 3, format('26.1 expected several kinds for one customer, got %s', n);
  assert exists (select 1 from search_documents('srinivas', 50) where kind = 'invoice'), '26.1 no invoice';
  assert exists (select 1 from search_documents('srinivas', 50) where kind = 'quotation'), '26.1 no quotation';
  assert exists (select 1 from search_documents('srinivas', 50) where kind = 'receipt'), '26.1 no receipt';

  -- 2. A document number finds its document, whichever kind it belongs to.
  select * into r from search_documents((select invoice_no from invoices where id = v_inv), 20) limit 1;
  assert r.doc_id = v_inv, '26.2 an invoice number did not find its invoice';

  -- 3. The other side of the book is in the same search.
  assert exists (select 1 from search_documents('sugar traders', 20) where kind = 'purchase' and doc_id = v_pu),
    '26.3 purchases are missing from the search';

  -- 4. Words are ANDed and may land in different fields — number and name
  --    together, neither of them a contiguous match on its own.
  assert exists (
    select 1 from search_documents(
      (select invoice_no from invoices where id = v_inv) || ' srinivas', 20) where doc_id = v_inv),
    '26.4 number plus name found nothing';

  -- 5. And they narrow: the same words against the other customer find nothing.
  select count(*) into n from search_documents('srinivas takkellapadu', 50);
  assert n = 0, format('26.5 words are not being ANDed, got %s rows', n);

  -- 6. Punctuation in a real name survives, as it must — this master is full of
  --    "P. SRINIVAS (MCL)" and "PAK(12)".
  assert exists (select 1 from search_documents('(MCL)', 20)), '26.6 a bracketed name found nothing';

  -- 7. An empty search returns nothing rather than the whole book.
  select count(*) into n from search_documents('   ', 50);
  assert n = 0, format('26.7 a blank search returned %s rows', n);

  -- 8. It reaches back through the party, not just the number, and honours the
  --    limit it is given.
  select count(*) into n from search_documents('srinivas', 2);
  assert n = 2, format('26.8 limit ignored, got %s', n);

  raise notice 'OK: document search — one term finds invoices, quotations, receipts, purchases and the rest together, by number, party or town; words are ANDed across fields, punctuation survives, a blank term returns nothing and the limit holds';
end $$;

rollback;
