-- ============================================================
-- DB acceptance test: the master reset. Rolls back.
--
-- This is the one function in the system that destroys a shop's records on
-- purpose, so the test spends most of its effort on the things that must
-- SURVIVE. A reset that deletes too much locks the shop out of its own system,
-- and unlike a reset that deletes too little, nobody finds out until they try
-- to log in.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_loc uuid; v_cust uuid; v_sup uuid; v_item uuid; v_sec uuid;
  v_inv uuid; v_pur uuid; v_msg text; n bigint;
  uid_owner uuid := gen_random_uuid();
  uid_admin uuid := gen_random_uuid();

begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into staff (org_id, full_name, role, auth_uid) values (v_org, 'K. RAMESH', 'admin', uid_admin);
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into sections (org_id, name) values (v_org,'OUTER') returning id into v_sec;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into suppliers (org_id, name) values (v_org,'SUGAR TRADERS') returning id into v_sup;
  insert into items (org_id, item_code, name, section_id, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'2760','1/- KALAJAM(12)', v_sec, v_jar, 12, 1, 15, 10) returning id into v_item;

  v_pur := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 50, 'rate', 10)));
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 15)));
  perform set_invoice_status(v_inv, 'confirmed');

  --    Something in the ledger, the stock and the numbering to check against.
  select count(*) into n from stock_ledger where org_id = v_org;
  assert n >= 2, format('44.0 the test shop has %s stock rows', n);
  assert exists (select 1 from journal_entries where org_id = v_org), '44.0 nothing in the ledger';

  -- ============================================================
  -- 1. IT REFUSES UNTIL THE NAME IS TYPED. Every other guard can be argued
  --    with; this one is the difference between meaning it and clicking it.
  -- ============================================================
  begin
    perform master_reset('yes', 'transactions');
    raise exception '44.1 a reset went ahead on "yes"';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%JYOTHI FOODS%', format('44.1 does not say what to type: %s', v_msg);
    assert v_msg like '%cannot be undone%', format('44.1 does not warn: %s', v_msg);
    assert v_msg like '%backup%', format('44.1 does not mention a backup: %s', v_msg);
  end;
  assert exists (select 1 from invoices where org_id = v_org), '44.1 it deleted anyway';

  --    And a near miss is a miss.
  begin
    perform master_reset('JYOTHI FOOD', 'transactions');
    raise exception '44.2 a reset went ahead on a name that was nearly right';
  exception when sqlstate '42501' then null;
  end;

  -- ============================================================
  -- 2. ONLY AN OWNER.
  -- ============================================================
  perform set_config('request.jwt.claim.sub', uid_admin::text, true);
  begin
    perform master_reset('JYOTHI FOODS', 'transactions');
    raise exception '44.3 an admin reset the shop';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%owner%', format('44.3 wrong reason: %s', v_msg);
  end;
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);

  --    A scope nobody meant is refused rather than guessed at.
  begin
    perform master_reset('JYOTHI FOODS', 'evrything');
    raise exception '44.4 a misspelt scope was accepted';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%transactions, masters or everything%', format('44.4 wrong reason: %s', v_msg);
  end;

  -- ============================================================
  -- 3. SCOPE "transactions": the documents go, the shop stays.
  -- ============================================================
  select count(*) into n from master_reset('JYOTHI FOODS', 'transactions');
  assert n > 0, '44.5 the reset reported nothing at all';

  assert not exists (select 1 from invoices where org_id = v_org), '44.5 a bill survived';
  assert not exists (select 1 from purchases where org_id = v_org), '44.5 a purchase survived';
  assert not exists (select 1 from stock_ledger where org_id = v_org), '44.5 stock movements survived';
  assert not exists (select 1 from journal_entries where org_id = v_org), '44.5 the ledger survived';
  --    Lines go with their documents rather than being left pointing at nothing.
  assert not exists (select 1 from invoice_items), '44.5 bill lines were orphaned';
  assert not exists (select 1 from purchase_items), '44.5 purchase lines were orphaned';

  --    THE PART THAT MATTERS: everything the shop spent weeks typing is intact.
  assert exists (select 1 from items where id = v_item), '44.6 the product list was destroyed';
  assert exists (select 1 from customers where id = v_cust), '44.6 the customers were destroyed';
  assert exists (select 1 from suppliers where id = v_sup), '44.6 the suppliers were destroyed';
  assert exists (select 1 from uoms where id = v_jar), '44.6 the units were destroyed';
  assert exists (select 1 from sections where id = v_sec), '44.6 the sections were destroyed';
  assert exists (select 1 from stock_locations where id = v_loc), '44.6 the godowns were destroyed';

  --    And nobody is locked out.
  select count(*) into n from staff where org_id = v_org;
  assert n = 2, format('44.7 %s staff left of two', n);
  assert exists (select 1 from orgs where id = v_org and name = 'JYOTHI FOODS'), '44.7 the organisation went';
  assert exists (select 1 from role_permissions where org_id = v_org), '44.7 the permissions went';

  --    Bill one is bill one again.
  assert not exists (select 1 from number_series where org_id = v_org and next_number <> 1),
    '44.8 a counter was left where it was';

  --    And the stock window is open again, because the opening figures are
  --    about to be typed for a second time.
  assert stock_delete_open(v_org), '44.8 corrections were left closed for a shop starting over';

  -- ============================================================
  -- 4. SCOPE "masters": the product list goes too, Setup stays.
  -- ============================================================
  perform master_reset('JYOTHI FOODS', 'masters');
  assert not exists (select 1 from items where org_id = v_org), '44.9 the products survived a masters reset';
  assert not exists (select 1 from customers where org_id = v_org), '44.9 the customers survived';
  assert not exists (select 1 from suppliers where org_id = v_org), '44.9 the suppliers survived';
  assert exists (select 1 from uoms where id = v_jar), '44.9 the units went with the masters';
  assert exists (select 1 from stock_locations where id = v_loc), '44.9 the godowns went with the masters';
  assert exists (select 1 from staff where org_id = v_org and auth_uid = uid_owner), '44.9 the owner went';

  -- ============================================================
  -- 5. SCOPE "everything": back to the morning it was created, still able to
  --    log in.
  -- ============================================================
  perform master_reset('JYOTHI FOODS', 'everything');
  assert not exists (select 1 from uoms where org_id = v_org), '44.10 the units survived everything';
  assert not exists (select 1 from sections where org_id = v_org), '44.10 the sections survived';
  assert not exists (select 1 from stock_locations where org_id = v_org), '44.10 the godowns survived';

  --    The four things that must outlive even "everything".
  assert exists (select 1 from orgs where id = v_org), '44.11 the organisation was deleted';
  assert exists (select 1 from staff where org_id = v_org and auth_uid = uid_owner and role = 'owner'),
    '44.11 the owner lost their login';
  assert exists (select 1 from role_permissions where org_id = v_org), '44.11 the permissions were deleted';
  assert exists (select 1 from number_series where org_id = v_org), '44.11 the numbering set-up was deleted';

  -- ============================================================
  -- 6. RUNNING IT TWICE IS HARMLESS. Somebody will press it again to be sure.
  -- ============================================================
  select count(*) into n from master_reset('JYOTHI FOODS', 'everything');
  assert n = 0, format('44.12 a second reset found %s tables still holding rows', n);

  raise notice 'OK: master reset — refused until the business name is typed exactly, refused for anybody but an owner, refused on a scope nobody meant; transactions clears every document and stock and ledger row while products, customers and Setup stay; masters also clears the product list but leaves Setup; everything goes back to the first morning — and at every scope the organisation, the staff logins, the permissions and the numbering set-up survive, the counters go back to 1, and running it twice does nothing';
end $$;

rollback;
