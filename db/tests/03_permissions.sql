-- ============================================================
-- DB acceptance test: role_permissions is what RLS consults.
-- T0.3: "A sales_exec cannot see Production or Payments, and
-- hitting those URLs directly is blocked by RLS, not the router."
-- Rolls back at the end.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_item uuid;
  uid_owner uuid := gen_random_uuid();
  uid_sales uuid := gen_random_uuid();
  uid_acct  uuid := gen_random_uuid();
  n int; v_no text; v_inv uuid;
begin
  -- Owner bootstraps the org through the RPC, the way the wizard does ----
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  assert v_org is not null, 'bootstrap_org should return the org id';
  select count(*) into n from v_me;
  assert n = 1, 'v_me should return the caller';
  select count(*) into n from role_permissions;
  assert n = 7 * 15, format('seed should create 7 roles × 15 modules = 105 rows, got %s', n);

  begin
    perform bootstrap_org('SECOND ORG', 'Owner again');
    raise exception 'a user with a staff row must not bootstrap a second org';
  exception when others then
    if sqlerrm not like '%already belongs%' then raise; end if;
  end;

  -- Owner sets up masters and two more users -------------------------------
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org, 'Cust') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '1', '5/- BOONDI LADDU (8)', v_uom, 8, 8, 120) returning id into v_item;
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_sales, 'Sales', 'sales_exec');
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_acct,  'Accounts', 'accountant');
  insert into payments (org_id, amount, narration) values (v_org, 500, 'diesel');
  insert into production_batches (org_id, item_id, no_of_plates) values (v_org, v_item, 10);

  -- Sales exec: no production, no payments, but can invoice -----------------
  perform set_config('request.jwt.claim.sub', uid_sales::text, true);
  assert can_view('invoices'),        'sales_exec should view invoices';
  assert not can_view('production'),  'sales_exec must not view production';
  assert not can_view('payments'),    'sales_exec must not view payments';
  assert not can_edit('setup'),       'sales_exec must not edit setup';

  select count(*) into n from production_batches;
  assert n = 0, format('RLS must hide production_batches from sales_exec, saw %s', n);
  select count(*) into n from payments;
  assert n = 0, format('RLS must hide payments from sales_exec, saw %s', n);

  begin
    insert into payments (org_id, amount) values (v_org, 1);
    raise exception 'sales_exec must not insert payments';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into uoms (org_id, code, name, basis) values (v_org, 'X', 'x', 'unit');
    raise exception 'sales_exec must not edit setup lookups';
  exception when insufficient_privilege then null;
  end;

  -- …but numbering + invoicing work without Setup rights (definer next_doc_no)
  v_no := next_doc_no(v_org, 'invoice');
  assert v_no = '0001', format('invoice number: %s', v_no);
  insert into invoices (org_id, invoice_no, customer_id, location_id)
    values (v_org, v_no, v_cust, v_loc) returning id into v_inv;
  insert into invoice_items (invoice_id, item_id, boxes, rate) values (v_inv, v_item, 1, 120);
  update invoices set status = 'confirmed' where id = v_inv;
  select count(*) into n from stock_ledger where ref_id = v_inv;
  assert n = 1, 'sales_exec confirming an invoice should post stock';

  begin
    perform next_doc_no(gen_random_uuid(), 'invoice');
    raise exception 'must not number documents for another org';
  exception when others then
    if sqlerrm not like '%another organisation%' then raise; end if;
  end;

  -- Accountant: payments yes, production no ---------------------------------
  perform set_config('request.jwt.claim.sub', uid_acct::text, true);
  select count(*) into n from payments;
  assert n = 1, 'accountant should see payments';
  insert into payments (org_id, amount) values (v_org, 2);
  select count(*) into n from production_batches;
  assert n = 0, 'accountant must not see production';

  -- It is the TABLE that decides: owner flips a row, sales_exec now sees it
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  update role_permissions set can_view = true
   where org_id = v_org and role = 'sales_exec' and module = 'production';
  perform set_config('request.jwt.claim.sub', uid_sales::text, true);
  select count(*) into n from production_batches;
  assert n = 1, 'after the owner grants production view, sales_exec should see the batch';

  reset role;
  raise notice 'OK: role_permissions drives RLS; sales_exec is blocked from production and payments';
end $$;

rollback;
