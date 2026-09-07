-- ============================================================
-- DB acceptance test: RLS is the security boundary.
-- Runs as the Supabase `authenticated` role with a JWT claim, the
-- way PostgREST does, so every policy is exercised for real.
-- Rolls back at the end.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/02_rls.sql
--
-- On a bare local Postgres (not Supabase) the `authenticated` role
-- has no grants; the GRANTs below mirror Supabase's defaults and are
-- harmless on a real project.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  org_a uuid; org_b uuid;
  uid_a uuid := gen_random_uuid();
  uid_b uuid := gen_random_uuid();
  uom_a uuid; uom_b uuid;
  loc_a uuid; loc_b uuid;
  cust_a uuid; cust_b uuid;
  item_a uuid; item_b uuid;
  inv_a uuid;
  n int; q numeric;
begin
  -- Two orgs, one staff member each -------------------------------
  insert into orgs (name) values ('ORG A') returning id into org_a;
  insert into orgs (name) values ('ORG B') returning id into org_b;
  insert into staff (org_id, auth_uid, full_name, role) values (org_a, uid_a, 'Owner A', 'owner');
  insert into staff (org_id, auth_uid, full_name, role) values (org_b, uid_b, 'Sales B', 'sales_exec');
  insert into uoms (org_id, code, name, basis) values (org_a, 'JAR', 'Jar', 'unit') returning id into uom_a;
  insert into uoms (org_id, code, name, basis) values (org_b, 'JAR', 'Jar', 'unit') returning id into uom_b;
  insert into stock_locations (org_id, name) values (org_a, 'Godown A') returning id into loc_a;
  insert into stock_locations (org_id, name) values (org_b, 'Godown B') returning id into loc_b;
  insert into customers (org_id, name) values (org_a, 'Cust A') returning id into cust_a;
  insert into customers (org_id, name) values (org_b, 'Cust B') returning id into cust_b;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (org_a, '1', '5/- BOONDI LADDU (8)', uom_a, 8, 8, 120) returning id into item_a;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (org_b, '1', '5/- BOONDI LADDU (8)', uom_b, 8, 8, 120) returning id into item_b;

  -- Become Owner A, the way PostgREST would ------------------------
  perform set_config('request.jwt.claim.sub', uid_a::text, true);
  set local role authenticated;

  assert my_org_id() = org_a, 'my_org_id() should resolve from the JWT';
  assert my_role() = 'owner', 'my_role() should resolve from the JWT';

  -- Org isolation ---------------------------------------------------
  select count(*) into n from items;
  assert n = 1, format('Owner A should see 1 item, saw %s', n);
  select count(*) into n from customers where id = cust_b;
  assert n = 0, 'Owner A must not see Org B customers';
  select count(*) into n from orgs;
  assert n = 1, format('Owner A should see only their own org, saw %s', n);

  -- Cannot write into another org ---------------------------------
  begin
    insert into customers (org_id, name) values (org_b, 'smuggled');
    raise exception 'RLS allowed a cross-org insert';
  exception when insufficient_privilege then null;
  end;

  -- Invoice lifecycle under RLS: confirm, then dispatch --------------
  insert into invoices (org_id, invoice_no, customer_id, location_id)
    values (org_a, 'A-1', cust_a, loc_a) returning id into inv_a;
  insert into invoice_items (invoice_id, item_id, boxes, rate) values (inv_a, item_a, 2, 120);

  update invoices set status = 'confirmed' where id = inv_a;
  select coalesce(sum(qty_base),0) into q from stock_ledger where item_id = item_a and location_id = loc_a;
  assert q = -16, format('after confirm stock should be -16 units, got %s', q);

  update invoices set status = 'dispatched' where id = inv_a;
  select coalesce(sum(qty_base),0) into q from stock_ledger where item_id = item_a and location_id = loc_a;
  assert q = -16, format('dispatch must not post stock again; expected -16, got %s', q);

  update invoices set status = 'cancelled' where id = inv_a;
  select coalesce(sum(qty_base),0) into q from stock_ledger where item_id = item_a and location_id = loc_a;
  assert q = 0, format('cancel must return stock to 0, got %s', q);

  -- Ledger is append-only even for the owner ----------------------
  begin
    delete from stock_ledger where item_id = item_a;
    get diagnostics n = row_count;
    assert n = 0, 'owner must not be able to delete stock_ledger rows';
  exception when insufficient_privilege then null;
  end;

  -- Now become Sales B: cannot touch items or payments ----------------
  perform set_config('request.jwt.claim.sub', uid_b::text, true);
  begin
    insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit)
      values (org_b, '2', 'X', uom_b, 8, 8);
    raise exception 'sales_exec must not be able to create items';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into payments (org_id, amount) values (org_b, 10);
    raise exception 'sales_exec must not be able to create payments';
  exception when insufficient_privilege then null;
  end;

  -- audit_log and the 04 reporting views must not leak across orgs ----
  reset role;
  insert into audit_log (org_id, action) values (org_a, 'secret-a');
  insert into cash_bank_accounts (org_id, name, opening_balance) values (org_a, 'Cash A', 999);
  perform set_config('request.jwt.claim.sub', uid_b::text, true);
  set local role authenticated;
  select count(*) into n from audit_log where org_id = org_a;
  assert n = 0, format('Sales B can read Org A audit_log rows (%s)', n);
  select count(*) into n from v_account_balances where org_id = org_a;
  assert n = 0, format('Sales B can read Org A balances through v_account_balances (%s)', n);
  select count(*) into n from v_day_book where org_id = org_a;
  assert n = 0, format('Sales B can read Org A day book (%s)', n);

  reset role;
  raise notice 'OK: RLS isolates orgs, roles are enforced, stock posts once per status change';
end $$;

rollback;
