-- ============================================================
-- DB acceptance test: T11.2 licensing. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
revoke execute on function issue_license(uuid, date, text, integer) from authenticated;
revoke execute on function renew_license(uuid, date) from authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_cust uuid; v_item uuid; v_key text; j jsonb; n int; v_dev uuid;
  uid_owner uuid := gen_random_uuid(); uid_sales uuid := gen_random_uuid();
  new_invoice text;
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, 32, 12, 42) returning id into v_item;
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_sales, 'Sales', 'sales_exec');

  -- ===== trial: no key, documents allowed =====
  j := license_status('dev-1', '0.2.0');
  assert j->>'status' = 'trial' and (j->>'days_left')::int = 30 and (j->>'read_only')::boolean = false and (j->>'has_key')::boolean = false, format('trial %s', j);
  perform save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  select count(*) into n from invoices where org_id = v_org; assert n = 1;

  -- ===== trial over: read-only =====
  update orgs set created_at = now() - interval '40 days' where id = v_org;
  j := license_status();
  assert j->>'status' = 'unlicensed' and (j->>'read_only')::boolean, format('unlicensed %s', j);
  begin
    perform save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
    raise exception 'should fail';
  exception when others then assert sqlerrm like 'The licence has lapsed%', sqlerrm; end;
  select count(*) into n from invoices where org_id = v_org; assert n = 1, 'reads still work, nothing written';
  begin
    perform activate_license('JF-NOPE', 'dev-1'); raise exception 'should fail';
  exception when others then assert sqlerrm like 'No licence has been issued%', sqlerrm; end;

  -- ===== vendor issues a key (service call) =====
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform issue_license(v_org, current_date + 365, 'Jyothi Foods, Guntur', 2);
  exception when others then raise exception 'issue as service failed: %', sqlerrm; end;
  v_key := issue_license(v_org, current_date + 365, 'Jyothi Foods, Guntur', 2);
  assert v_key like 'JF-_____-_____-_____-_____', v_key;
  select license_key into new_invoice from orgs where id = v_org; assert new_invoice = license_hash(v_key) and new_invoice <> v_key, 'only the hash is stored';
  -- the service role is never blocked by the licence
  update orgs set license_valid_till = current_date - 30 where id = v_org;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table) values (v_org, v_item, v_loc, 'adjustment', current_date, 1, 'test');
  update orgs set license_valid_till = current_date + 365 where id = v_org;

  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  begin
    perform issue_license(v_org, current_date + 9999); raise exception 'should fail';
  exception when others then assert sqlerrm like '%permission denied%' or sqlerrm like 'Licences are issued%', sqlerrm; end;

  -- ===== activation =====
  begin
    perform activate_license('JF-WRONG-KEY00-00000-00000', 'dev-1'); raise exception 'should fail';
  exception when others then assert sqlerrm = 'Licence key not recognised', sqlerrm; end;
  j := activate_license(lower(v_key), 'dev-1', 'Billing PC', 'win32', '0.2.0');   -- case and dashes do not matter
  assert j->>'status' = 'active' and (j->>'days_left')::int = 365 and (j->>'this_device_known')::boolean and (j->>'devices')::int = 1 and j->>'licensed_to' = 'Jyothi Foods, Guntur', format('active %s', j);
  perform activate_license(v_key, 'dev-2', 'Godown laptop', 'win32', '0.2.0');
  begin
    perform activate_license(v_key, 'dev-3', 'Third', 'win32', '0.2.0'); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Device limit reached (2)%', sqlerrm; end;
  perform activate_license(v_key, 'dev-2', 'Godown laptop renamed', 'win32', '0.2.1');   -- known device: fine
  select count(*) into n from v_license_devices; assert n = 2;
  select id into v_dev from license_devices where device_id = 'dev-2';
  perform remove_license_device(v_dev);
  perform activate_license(v_key, 'dev-3', 'Third', 'win32', '0.2.0');
  select count(*) into n from license_devices where org_id = v_org; assert n = 2, 'slot freed';
  j := license_status('dev-9'); assert (j->>'this_device_known')::boolean = false, 'unknown device is not registered by a status check';
  perform save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));

  -- ===== grace, then expired =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform renew_license(v_org, current_date - 3);
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  j := license_status();
  assert j->>'status' = 'grace' and (j->>'read_only')::boolean = false and (j->>'days_left')::int = -3, format('grace %s', j);
  perform save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  select count(*) into n from invoices where org_id = v_org; assert n = 3, 'grace still writes';

  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform renew_license(v_org, current_date - 8);
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  j := license_status();
  assert j->>'status' = 'expired' and (j->>'read_only')::boolean, format('expired %s', j);
  begin
    perform save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
    raise exception 'should fail';
  exception when others then assert sqlerrm like 'The licence has lapsed%', sqlerrm; end;
  begin
    perform save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date), jsonb_build_array()); raise exception 'should fail';
  exception when others then assert sqlerrm like 'The licence has lapsed%' or sqlerrm like '%line%', sqlerrm; end;
  select count(*) into n from v_invoice_list; assert n = 3, 'lists still readable when expired';
  update customers set town = 'GUNTUR' where id = v_cust;   -- masters are not documents; the UI goes read-only, the DB does not block

  -- ===== renewal brings it back =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform renew_license(v_org, current_date + 30);
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  j := license_status(); assert j->>'status' = 'active' and (j->>'days_left')::int = 30, format('renewed %s', j);
  perform save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));

  -- ===== not for a sales exec =====
  perform set_config('request.jwt.claim.sub', uid_sales::text, true);
  begin
    perform activate_license(v_key, 'dev-5'); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Only the owner or an admin%', sqlerrm; end;
  j := license_status(); assert j->>'status' = 'active', 'anyone in the org may ask the status';

  reset role;
  raise notice 'OK: licensing — trial → unlicensed (read-only, reads fine), vendor-issued key stored as a hash, activation registers devices up to the limit (remove frees a slot), grace writes, expired blocks documents, renewal restores, service role never blocked';
end $$;

rollback;
