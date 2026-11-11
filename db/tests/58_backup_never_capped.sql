-- ============================================================
-- DB acceptance test: a shop can always take its own books out.
--
-- "Backup not working." It was not broken: backup sat inside Owner control, a
-- FULL-plan feature, so a shop capped to Starter had no Backup tab at all.
-- A licence decides what a shop may DO with the software; it must not decide
-- whether they can have a copy of their own invoices — least of all on the
-- day the account is in dispute, which is exactly when they want one.
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
  v_org uuid; uid uuid := gen_random_uuid(); j jsonb; v_msg text; n int;
  v_jar uuid; v_loc uuid; v_item uuid; v_cust uuid; v_inv uuid;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');

  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'RAVI STORES') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','MYSOOR PAK', v_jar, 10, 1, 10) returning id into v_item;
  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base)
    values (v_org,v_item,v_loc,'opening',current_date-10, 10000);
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date::text, 'location_id', v_loc),
                        jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 10)));
  perform set_invoice_status(v_inv, 'confirmed');

  -- ===== 58.1 on Full, as before =====
  select org_snapshot() into j;
  assert j ? 'tables', '58.1 a snapshot has tables in it';
  assert jsonb_array_length(j->'tables'->'invoices') = 1, '58.1 and the shop''s bill is in it';

  -- ===== 58.2 capped to Starter, the shop can STILL take its books out =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform set_license_plan(v_org, 'starter');
  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
  assert my_plan() = 'starter', format('58.2 should be capped, is %s', my_plan());

  select org_snapshot() into j;
  assert jsonb_array_length(j->'tables'->'invoices') = 1,
    '58.2 a capped shop must still be able to back up its own invoices';
  assert j->'org' ? 'name', '58.2 and its own details';
  -- the licence key is never in a backup, capped or not
  assert not (j->'org' ? 'license_key'), '58.2 a backup must not carry the licence key';

  -- ===== 58.3 the rest of Owner control stays behind the plan =====
  begin
    perform require_feature('owner');
    raise exception '58.3 the cap leaked — print designer and audit are open on Starter';
  -- require_feature raises P0001, not 42501
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%not part of your Starter licence%', format('58.3 wrong reason: %s', v_msg);
  end;

  -- ===== 58.4 and it is still the owner only =====
  -- demote and promote from outside the app: a store keeper cannot edit
  -- staff, so doing it as one leaves the test stuck as a store keeper
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  update staff set role = 'store_keeper' where org_id = v_org and auth_uid = uid;
  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
  begin
    perform org_snapshot();
    raise exception '58.4 a store keeper took a backup of the whole business';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%Only the owner%', format('58.4 wrong reason: %s', v_msg);
  end;
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  update staff set role = 'owner' where org_id = v_org and auth_uid = uid;
  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;

  -- ===== 58.5 a backup can be read back, and it carries what it should =====
  select org_snapshot() into j;
  select count(*) into n from jsonb_object_keys(j->'tables');
  assert n > 40, format('58.5 a snapshot should cover the whole business, covers %s tables', n);
  assert (j->>'org_id')::uuid = v_org, '58.5 and says whose it is, so it cannot be restored into another shop';

  raise notice 'OK: a shop capped to Starter can still take a complete backup of its own books — every table, its own details, and its own id so it can never be restored into somebody else''s shop — while the print designer and audit trail stay behind the Full plan and a store keeper still cannot back up the business; the licence key is never in the file';
end $$;

rollback;
