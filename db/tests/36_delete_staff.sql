-- ============================================================
-- DB acceptance test: deleting a user. Rolls back.
--
-- Two of these refusals are not about references at all. They are the two ways
-- to lock a shop out of its own system permanently — delete yourself, or delete
-- the last owner — and neither leaves any way back in from the app, so neither
-- can be left to the browser to remember.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_item uuid;
  v_owner uuid; v_spare uuid; v_third uuid; v_typo uuid; v_clerk uuid; v_inv uuid;
  v_msg text; n bigint;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  select id into v_owner from staff where org_id = v_org and auth_uid = uid_owner;
  assert v_owner is not null, '36.0 bootstrap made no owner';

  insert into staff (org_id, full_name, role) values (v_org, 'TYPED BY MISTAKE', 'sales_exec') returning id into v_typo;
  insert into staff (org_id, full_name, role) values (v_org, 'K. RAMESH', 'accountant') returning id into v_clerk;

  -- 1. A user nobody has used simply goes.
  assert delete_staff(v_typo) = 'deleted', '36.1 an unused user would not delete';
  assert not exists (select 1 from staff where id = v_typo), '36.1 still there';

  -- 2. YOURSELF. This is the one with no way back: no staff row means no
  --    organisation, and the app will not let you in to undo it.
  begin
    perform delete_staff(v_owner);
    raise exception '36.2 a user deleted their own login';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%your own login%', format('36.2 wrong reason: %s', v_msg);
    assert v_msg like '%another owner%', format('36.2 does not say who can do it: %s', v_msg);
  end;
  assert exists (select 1 from staff where id = v_owner), '36.2 it went anyway';

  -- 3. THE LAST OWNER. Even asked by somebody else, even with nothing pointing
  --    at them, because the shop would have nobody left who can manage users.
  insert into staff (org_id, full_name, role) values (v_org, 'SECOND OWNER', 'owner') returning id into v_spare;
  insert into staff (org_id, full_name, role) values (v_org, 'THIRD OWNER', 'owner') returning id into v_third;
  -- While others remain, an owner goes like anybody else.
  assert delete_staff(v_third) = 'deleted', '36.3 an owner would not delete while another remained';

  -- Leave SECOND OWNER as the only one by standing the caller down to admin.
  -- Deactivating the caller instead would be the obvious way to write this and
  -- it breaks the test rather than the code: my_org_id() reads the signed-in
  -- staff row and requires is_active, so an inactive caller belongs to no
  -- organisation and every call after it fails on that instead.
  update staff set role = 'admin' where id = v_owner;
  begin
    perform delete_staff(v_spare);
    raise exception '36.4 the only owner was deleted';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%only owner%', format('36.4 wrong reason: %s', v_msg);
    assert v_msg like '%SECOND OWNER%', format('36.4 does not name them: %s', v_msg);
  end;
  update staff set role = 'owner' where id = v_owner;
  assert delete_staff(v_spare) = 'deleted', '36.4 it would not go once a second owner was back';

  -- 4. Work they did still holds them, through delete_master — the reference
  --    rules were never copied here and must not start drifting.
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42) returning id into v_item;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 1000, 30);
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  update invoices set created_by = v_clerk where id = v_inv;

  begin
    perform delete_staff(v_clerk);
    raise exception '36.5 a user who had entered a bill was deleted';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%bill%', format('36.5 wrong reason: %s', v_msg);
    assert v_msg like '%inactive%', format('36.5 does not offer the way out: %s', v_msg);
  end;

  -- 5. Gone means gone.
  begin
    perform delete_staff(v_typo);
    raise exception '36.6 deleting a user twice reported success';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%not there any more%', format('36.6 wrong reason: %s', v_msg);
  end;

  select count(*) into n from staff where org_id = v_org;
  assert n = 2, format('36.7 expected the owner and the clerk left, got %s', n);
  assert exists (select 1 from staff where id = v_owner and role = 'owner' and is_active),
    '36.7 the signed-in owner did not survive the test intact';

  raise notice 'OK: delete a user — an unused one goes; deleting yourself is refused and says who can do it instead; the last owner is refused by name while a second owner makes it allowed; work already entered still holds them through delete_master with Set inactive offered; and a second go says it is already gone';
end $$;

rollback;
