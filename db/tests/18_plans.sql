-- ============================================================
-- DB acceptance test: three licence plans. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
revoke execute on function issue_license(uuid, date, text, integer, text) from authenticated;
revoke execute on function set_license_plan(uuid, text) from authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_cust uuid; v_item uuid; v_sup uuid; v_cash uuid; v_inv uuid; v_key text;
  j jsonb; r record; n int;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into stock_locations (org_id, name) values (v_org, 'Shop');
  insert into customers (org_id, name, town, mobile1) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746') returning id into v_cust;
  insert into suppliers (org_id, name) values (v_org, 'RAW SUPPLIER') returning id into v_sup;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order) values (v_org, 'CASH', 'Cash', true, false, 1) returning id into v_cash;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, 32, 12, 42) returning id into v_item;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table) values (v_org, v_item, v_loc, 'opening', current_date, 3200, 'test');

  -- ===== a fresh organisation is Full for its trial, so the client sees everything =====
  j := license_status();
  assert j->>'plan' = 'full' and j->>'plan_name' = 'Full', format('trial plan %s', j);
  assert jsonb_array_length(j->'catalogue') = 13, format('catalogue %s', jsonb_array_length(j->'catalogue'));
  assert has_feature('messaging') and has_feature('owner') and has_feature('core');
  -- work made while everything was open
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  perform save_quotation(jsonb_build_object('customer_id', v_cust, 'quote_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  insert into message_templates (org_id, name, purpose, language, channel, body) values (v_org, 'Reminder', 'payment_reminder', 'te', 'whatsapp', 'బకాయి {{outstanding}}');

  -- ===== the vendor issues a Starter key =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  v_key := issue_license(v_org, current_date + 365, 'Jyothi Foods, Guntur', 3, 'starter');
  assert v_key like 'JF-_____-_____-_____-_____', format('key shape: %s', v_key);
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;

  j := license_status();
  assert j->>'plan' = 'starter' and j->>'status' = 'active' and (j->>'read_only')::boolean = false, format('starter %s', j);
  assert j->'features' = '["core"]'::jsonb, format('starter features %s', j->'features');

  -- billing and collection still work
  assert can_view('invoices') and can_edit('invoices') and can_view('receipts') and can_view('items') and can_view('setup');
  perform save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  perform save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date), jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 500)));

  -- the rest is capped, and the database says so — not just the screen
  assert not can_view('purchases') and not can_edit('purchases'), 'purchases locked';
  assert not can_view('payments') and not can_view('production') and not can_view('vehicles') and not can_view('messaging'), 'growth and full modules locked';
  assert not has_feature('documents') and not has_feature('inventory') and not has_feature('owner') and not has_feature('insights') and not has_feature('mobile');
  begin
    insert into purchases (org_id, bill_no, supplier_id, location_id, bill_date) values (v_org, 'X1', v_sup, v_loc, current_date);
    raise exception 'should fail';
  exception when insufficient_privilege or others then assert sqlerrm like '%row-level security%' or sqlerrm like '%policy%', sqlerrm; end;
  begin
    perform save_quotation(jsonb_build_object('customer_id', v_cust, 'quote_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
    raise exception 'should fail';
  exception when others then assert sqlerrm like '%row-level security%' or sqlerrm like '%policy%', sqlerrm; end;
  begin
    perform save_stock_transfer(jsonb_build_object('from_location', v_loc, 'to_location', (select id from stock_locations where org_id = v_org and name = 'Shop'), 'txn_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1)));
    raise exception 'should fail';
  exception when others then assert sqlerrm like '%row-level security%' or sqlerrm like '%policy%', sqlerrm; end;
  begin
    perform org_snapshot(); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Owner control is not part of your Starter licence%' and sqlerrm like '%Full plan%', sqlerrm; end;
  begin
    perform route_profitability(v_org, current_date, current_date); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Profit & incentives is not part of your Starter licence%', sqlerrm; end;
  begin
    perform my_open_trip(); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Driver''s phone is not part of your Starter licence%', sqlerrm; end;
  begin
    insert into message_templates (org_id, name, purpose, language, channel, body) values (v_org, 'Blocked', 'invoice', 'te', 'whatsapp', 'x');
    raise exception 'should fail';
  exception when others then assert sqlerrm like '%row-level security%' or sqlerrm like '%policy%', sqlerrm; end;

  -- Nothing is deleted by a cap. A feature inside a module the plan allows stays readable
  -- and only stops taking new rows; a whole locked module hides its screens and its data
  -- until the plan opens again.
  select count(*) into n from quotations where org_id = v_org; assert n = 1, 'the trial quotation is still readable';
  select count(*) into n from message_templates where org_id = v_org; assert n = 0, 'a locked module hides its rows';
  select total into r from invoices where id = v_inv; assert r.total = 2688, 'the invoice is untouched';

  -- ===== Growth opens the rest of the operation =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  assert set_license_plan(v_org, 'growth') = 'Growth';
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;

  assert can_view('purchases') and can_edit('purchases') and can_view('payments') and can_view('production') and can_view('vehicles');
  assert has_feature('documents');
  insert into purchases (org_id, bill_no, supplier_id, location_id, bill_date) values (v_org, 'X1', v_sup, v_loc, current_date);
  perform save_quotation(jsonb_build_object('customer_id', v_cust, 'quote_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  -- but the automatic half is still shut
  assert not can_view('messaging') and not has_feature('inventory') and not has_feature('owner') and not has_feature('insights') and not has_feature('mobile');
  begin
    perform org_snapshot(); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Owner control is not part of your Growth licence%', sqlerrm; end;
  begin
    perform save_stock_transfer(jsonb_build_object('from_location', v_loc, 'to_location', (select id from stock_locations where org_id = v_org and name = 'Shop'), 'txn_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1)));
    raise exception 'should fail';
  exception when others then assert sqlerrm like '%row-level security%' or sqlerrm like '%policy%', sqlerrm; end;

  -- ===== Full opens everything =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform set_license_plan(v_org, 'full');
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;

  assert can_view('messaging') and has_feature('inventory') and has_feature('owner') and has_feature('insights') and has_feature('mobile') and has_feature('desktop');
  perform save_stock_transfer(jsonb_build_object('from_location', v_loc, 'to_location', (select id from stock_locations where org_id = v_org and name = 'Shop'), 'txn_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1)));
  j := org_snapshot(); assert (j->>'org_id')::uuid = v_org, 'backup works on Full';
  select count(*) into n from route_profitability(v_org, current_date, current_date); assert n >= 1, 'route profit works on Full';
  insert into message_templates (org_id, name, purpose, language, channel, body) values (v_org, 'Call script', 'payment_reminder', 'te', 'ivr_call', 'నమస్కారం');
  assert queue_message(jsonb_build_object('customer_id', v_cust, 'purpose', 'payment_reminder', 'channel', 'ivr_call')) is not null, 'voice calls queue on Full';

  -- ===== plans belong to the vendor =====
  begin
    perform set_license_plan(v_org, 'full'); raise exception 'should fail';
  exception when others then assert sqlerrm like '%permission denied%' or sqlerrm like 'Plans are set by the vendor%', sqlerrm; end;
  begin
    perform issue_license(v_org, current_date + 365, null, null, 'full'); raise exception 'should fail';
  exception when others then assert sqlerrm like '%permission denied%' or sqlerrm like 'Licences are issued by the vendor%', sqlerrm; end;
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform issue_license(v_org, current_date + 365, null, null, 'platinum'); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Plan must be starter, growth or full', sqlerrm; end;

  raise notice 'OK: plans — a trial org is Full, an issued key sets the plan, Starter keeps billing and collection and the database itself refuses purchases, quotations, transfers, backup, route profit, the driver''s phone and messaging; trial data stays readable; Growth opens buying, paying, production, vans and documents but not the automatic half; Full opens everything including voice; only the vendor sets a plan';
end $$;

rollback;
