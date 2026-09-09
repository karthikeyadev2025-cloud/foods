-- ============================================================
-- DB acceptance test: the search finds people and products too. Rolls back.
--
-- The complaint this fixes: a supplier that was just created showed up nowhere.
-- The search returned their purchases, so until somebody bought from them there
-- was nothing at all — which reads exactly like the record was never saved.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_sup uuid; v_fresh uuid; v_item uuid; v_staff uuid;
  v_inv uuid; r record; n int;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into customers (org_id, code, name, town, mobile1)
    values (v_org, 'C-41', 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746') returning id into v_cust;
  insert into suppliers (org_id, name, town, mobile1)
    values (v_org, 'SUGAR TRADERS', 'GUNTUR', '9000000111') returning id into v_sup;
  -- The whole point: a supplier nobody has bought from yet.
  insert into suppliers (org_id, name, town, mobile1)
    values (v_org, 'NEW OIL MILLS', 'TENALI', '9000000222') returning id into v_fresh;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '8', 'HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42) returning id into v_item;
  insert into staff (org_id, full_name, phone, role, designation)
    values (v_org, 'RAMANA MESTRI', '9876500011', 'chief', 'Sweets mestri') returning id into v_staff;

  -- 1. A supplier with no purchases against them is found. Before 35 this was
  --    the bug: no document mentioned them, so nothing came back.
  assert exists (select 1 from search_documents('NEW OIL', 20) where kind = 'supplier' and doc_id = v_fresh),
    '28.1 a supplier with no bills yet was invisible';
  assert exists (select 1 from search_documents('TENALI', 20) where doc_id = v_fresh), '28.1 by town';
  assert exists (select 1 from search_documents('9000000222', 20) where doc_id = v_fresh), '28.1 by phone';

  -- 2. Customers, products and staff come back the same way.
  assert exists (select 1 from search_documents('srinivas', 20) where kind = 'customer' and doc_id = v_cust), '28.2 customer';
  assert exists (select 1 from search_documents('C-41', 20) where kind = 'customer'), '28.2 customer code';
  assert exists (select 1 from search_documents('mysoor', 20) where kind = 'item' and doc_id = v_item), '28.2 item';
  assert exists (select 1 from search_documents('ramana', 20) where kind = 'staff' and doc_id = v_staff), '28.2 staff';
  assert exists (select 1 from search_documents('sweets mestri', 20) where doc_id = v_staff), '28.2 designation';

  -- 3. The record comes ABOVE its own documents, because it is the page that
  --    shows the phone, the outstanding and every bill at once.
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 1000, 30);
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  select * into r from search_documents('srinivas', 20) limit 1;
  assert r.kind = 'customer', format('28.3 expected the customer first, got %s', r.kind);
  assert exists (select 1 from search_documents('srinivas', 20) where kind = 'invoice'),
    '28.3 the bills stopped coming back once the record was added';

  -- 4. A master carries the figure that matters for its kind, so the row is
  --    worth reading before clicking it.
  select * into r from search_documents('srinivas', 20) where kind = 'customer';
  assert r.doc_no = 'C-41', format('28.4 customer code missing: %s', r.doc_no);
  assert r.amount = 2688, format('28.4 expected the outstanding 2688, got %s', r.amount);
  assert r.doc_date is null, '28.4 a master must not pretend to have a date';
  select * into r from search_documents('mysoor', 20) where kind = 'item';
  assert r.amount = 42, format('28.4 expected the item rate 42, got %s', r.amount);

  -- 5. Words still AND across a record's own fields.
  assert exists (select 1 from search_documents('srinivas macharla', 20) where kind = 'customer'), '28.5 name plus town';
  select count(*) into n from search_documents('srinivas guntur', 20);
  assert n = 0, format('28.5 the AND stopped narrowing on masters, got %s', n);

  -- 6. An inactive record still answers, and says so, rather than vanishing —
  --    people search for the one they stopped precisely to check they stopped it.
  update suppliers set is_active = false where id = v_fresh;
  select * into r from search_documents('NEW OIL', 20) where kind = 'supplier';
  assert r.state = 'inactive', format('28.6 expected inactive, got %s', coalesce(r.state, 'null'));

  raise notice 'OK: search masters — a supplier with no bills yet is found by name, town or phone; customers, products and staff too; the record sorts above its own documents, carries its code and its own figure, has no invented date, still ANDs its words and still answers when inactive';
end $$;

rollback;
