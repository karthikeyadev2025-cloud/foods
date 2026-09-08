-- ============================================================
-- DB acceptance test: T10 owner control. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_cust uuid; v_item uuid; v_inv uuid; v_cash uuid; v_tpl uuid;
  snap jsonb; j jsonb; r record; n int; q numeric; v_extra uuid; v_led bigint;
  uid_owner uuid := gen_random_uuid(); uid_sales uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746') returning id into v_cust;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order) values (v_org, 'CASH', 'Cash', true, false, 1) returning id into v_cash;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, 32, 12, 42) returning id into v_item;
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  perform save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date), jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 1000)));

  -- ===== business profile columns reach v_me =====
  update orgs set logo_url = 'https://x/logo.png', signature_url = 'https://x/sign.png', email = 'jyothi@example.com', tagline = 'Sweets & savouries', bank_details = 'SBI 1234' where id = v_org;
  select logo_url, org_email, bank_details into r from v_me; assert r.logo_url = 'https://x/logo.png' and r.org_email = 'jyothi@example.com' and r.bank_details = 'SBI 1234', 'v_me carries the profile extras';

  -- ===== print template: one default per doc type, upsert =====
  v_tpl := save_print_template(jsonb_build_object('doc_type', 'invoice', 'paper', 'A5', 'show_fields', jsonb_build_object('jars', false, 'logo', true), 'terms', jsonb_build_array('Goods once sold', 'Subject to Guntur jurisdiction')));
  select paper, show_fields->>'jars' as jars, array_length(terms, 1) as nterms, is_default into r from print_templates where id = v_tpl;
  assert r.paper = 'A5' and r.jars = 'false' and r.nterms = 2 and r.is_default, format('template %s', to_jsonb(r));
  assert save_print_template(jsonb_build_object('doc_type', 'invoice', 'paper', 'A4', 'terms', jsonb_build_array('x'))) = v_tpl, 'same row updated';
  select paper into r from print_templates where id = v_tpl; assert r.paper = 'A4';

  -- ===== audit trail: insert, a diff-only update, delete; secrets stripped =====
  select count(*) into n from v_audit_log where table_name = 'customers' and action = 'INSERT' and row_id = v_cust::text; assert n = 1, format('customer insert audited %s', n);
  update customers set town = 'GUNTUR' where id = v_cust;
  select before, after, actor_name into r from v_audit_log where table_name = 'customers' and action = 'UPDATE' and row_id = v_cust::text order by id desc limit 1;
  assert r.before = jsonb_build_object('town', 'MACHARLA') and r.after = jsonb_build_object('town', 'GUNTUR') and r.actor_name = 'Owner', format('update diff %s / %s', r.before, r.after);
  update customers set town = 'GUNTUR' where id = v_cust;   -- no change → no row
  select count(*) into n from v_audit_log where table_name = 'customers' and action = 'UPDATE' and row_id = v_cust::text; assert n = 1, 'a no-op update is not audited';
  select count(*) into n from v_audit_log where table_name = 'invoices' and action = 'UPDATE' and row_id = v_inv::text and after ? 'status'; assert n = 1, 'status change audited';
  perform save_messaging_settings(jsonb_build_object('api_key', 'nk_secret_1234', 'is_enabled', true));
  select count(*) into n from audit_log where org_id = v_org and (before::text like '%nk_secret%' or after::text like '%nk_secret%'); assert n = 0, 'api key never in the trail';
  select count(*) into n from audit_search(p_table => 'customers'); assert n = 2, format('audit_search by table %s', n);
  select count(*) into n from audit_search(p_search => 'GUNTUR'); assert n >= 1;
  select count(*) into n from audit_search(p_action => 'INSERT', p_limit => 3); assert n = 3, 'limit honoured';

  -- ===== snapshot → mutate → restore =====
  snap := org_snapshot();
  assert (snap->>'org_id')::uuid = v_org and jsonb_array_length(snap->'tables'->'customers') = 1 and jsonb_array_length(snap->'tables'->'invoice_items') = 1
     and jsonb_array_length(snap->'tables'->'stock_ledger') = 1 and jsonb_array_length(snap->'tables'->'journal_lines') >= 4, format('snapshot shape: %s customers, %s ledger rows', jsonb_array_length(snap->'tables'->'customers'), jsonb_array_length(snap->'tables'->'stock_ledger'));
  assert snap->'org'->>'license_key' is null and snap->'org'->>'name' = 'JYOTHI FOODS', 'org profile in the file, licence out';
  select max(id) into v_led from stock_ledger where org_id = v_org;
  -- things that happen after the backup
  insert into customers (org_id, name, town, mobile1) values (v_org, 'NEW SHOP', 'ONGOLE', '9000000009') returning id into v_extra;
  update items set unit_rate = 99 where id = v_item;
  perform set_invoice_status(save_invoice(jsonb_build_object('customer_id', v_extra, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 99))), 'confirmed');
  update orgs set name = 'RENAMED' where id = v_org;
  select count(*) into n from customers where org_id = v_org; assert n = 2;
  select count(*) into n from invoices where org_id = v_org; assert n = 2;

  j := restore_org_snapshot(snap);
  assert (j->'restored'->>'customers')::int = 1 and (j->'restored'->>'invoices')::int = 1, format('restore counts %s', j->'restored');
  select count(*) into n from customers where org_id = v_org; assert n = 1, 'the later customer is gone';
  select unit_rate into q from items where id = v_item; assert q = 42, format('rate back to %s', q);
  select count(*) into n from invoices where org_id = v_org; assert n = 1, 'the later invoice is gone';
  select total, status::text into r from invoices where id = v_inv; assert r.total = 2688 and r.status = 'confirmed', 'restored invoice intact (triggers off during copy)';
  select amount into q from invoice_items where invoice_id = v_inv; assert q = 2688, 'line values copied, not recomputed';
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_item; assert q = -64, format('stock back to the snapshot: %s', q);
  assert trial_balance_check(v_org) = 0, 'journal balanced after restore';
  select outstanding into q from v_customer_outstanding where customer_id = v_cust; assert q = 2688 - 1000;
  select name into r from orgs where id = v_org; assert r.name = 'JYOTHI FOODS', 'profile restored';
  select count(*) into n from staff where org_id = v_org; assert n = 1, 'staff kept';
  select count(*) into n from audit_log where org_id = v_org and action = 'RESTORE'; assert n = 1, 'restore itself audited';
  -- sequences moved past the restored ids: a new ledger row must not collide
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table) values (v_org, v_item, v_loc, 'adjustment', current_date, 1, 'test');
  select max(id) into r from stock_ledger where org_id = v_org; assert r.max > v_led, 'sequence continues after the restored ids';
  select count(*) into n from stock_ledger where org_id = v_org; assert n = 2;
  -- triggers are back on: a confirmed invoice posts stock again
  perform set_invoice_status(save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42))), 'confirmed');
  select count(*) into n from stock_ledger where org_id = v_org; assert n = 3, 'triggers re-enabled after restore';

  -- ===== settings + scheduler =====
  select auto_enabled, keep_copies, frequency into r from get_backup_settings(); assert r.auto_enabled and r.keep_copies = 30 and r.frequency = 'daily', 'defaults';
  -- Push the run hour away from now rather than trusting the default to differ. The
  -- default is 23:00 IST, so this assertion failed for one hour every night.
  update backup_settings set run_at = (((now() at time zone 'Asia/Kolkata')::time) + interval '3 hours')::time where org_id = v_org;
  select count(*) into n from backups_due(); assert n = 0, 'not due outside the run hour';
  update backup_settings set run_at = ((now() at time zone 'Asia/Kolkata')::time) where org_id = v_org;
  select count(*) into n from backups_due(); assert n = 1, 'due this hour';
  insert into backups (org_id, status, is_auto, file_path, size_bytes) values (v_org, 'ready', true, 'x', 10);
  select count(*) into n from backups_due(); assert n = 0, 'already taken today';

  -- ===== only the owner =====
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_sales, 'Sales', 'sales_exec');
  perform set_config('request.jwt.claim.sub', uid_sales::text, true);
  begin
    perform org_snapshot(); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Only the owner%', sqlerrm; end;
  begin
    perform restore_org_snapshot(snap); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Only the owner%', sqlerrm; end;
  begin
    perform save_print_template(jsonb_build_object('doc_type', 'invoice')); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Only Setup editors%', sqlerrm; end;
  select count(*) into n from v_audit_log; assert n = 0, 'a sales exec does not read the trail';

  reset role;
  raise notice 'OK: owner — profile extras on v_me, print template upsert (one default per type), audit trail (insert / diff-only update / delete, secrets stripped, search), snapshot → restore puts everything back with triggers off and sequences moved, scheduler due-list, owner-only';
end $$;

rollback;
