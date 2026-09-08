-- ============================================================
-- DB acceptance test: T6 Hey Nikki messaging.
-- Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_route uuid; v_a uuid; v_b uuid; v_c uuid; v_cash uuid; v_item uuid; v_inv uuid;
  t_gentle uuid; t_firm uuid; t_invoice uuid; t_receipt uuid; t_ack uuid; t_stock uuid; t_catalog uuid;
  r_gentle uuid; r_firm uuid; v_cat uuid; v_bc uuid; v_ord uuid; v_ord2 uuid; v_ord3 uuid; v_secret text; v_id uuid;
  j jsonb; r record; n int; q numeric; s text;
  uid_owner uuid := gen_random_uuid(); uid_sales uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  update orgs set credit_days = 10 where id = v_org;
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into routes (org_id, name) values (v_org, 'Macherla line') returning id into v_route;
  insert into customers (org_id, name, town, mobile1, route_id) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '98496 86746', v_route) returning id into v_a;
  insert into customers (org_id, name, town, mobile1, whatsapp_opt_in) values (v_org, 'OPTED OUT SHOP', 'GUNTUR', '9000000002', false) returning id into v_b;
  insert into customers (org_id, name, town) values (v_org, 'NO MOBILE SHOP', 'GUNTUR') returning id into v_c;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order) values (v_org, 'CASH', 'Cash', true, false, 1) returning id into v_cash;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, 32, 12, 42) returning id into v_item;

  -- ===== settings: key stored, never shown back in full =====
  j := save_messaging_settings(jsonb_build_object('api_key', 'nk_live_abcd1234', 'is_enabled', true, 'quiet_from', '00:00', 'quiet_to', '00:00', 'sender_number', '919000000000'));
  assert (j->>'has_api_key')::boolean and j->>'api_key_hint' = '••••1234' and j->>'api_key' is null, format('settings %s', j);
  v_secret := j->>'webhook_secret';
  assert length(v_secret) = 48, 'webhook secret generated';

  -- ===== templates in Telugu and English =====
  insert into message_templates (org_id, name, purpose, language, body) values
    (v_org, 'Reminder gentle (te)', 'payment_reminder', 'te', 'నమస్తే {{name}}, {{org}} బకాయి ₹{{outstanding}}. దయచేసి చెల్లించండి.') returning id into t_gentle;
  insert into message_templates (org_id, name, purpose, language, body) values
    (v_org, 'Reminder firm (en)', 'payment_reminder', 'en', 'Dear {{name}}, Rs {{outstanding}} is overdue by {{oldest_days}} days at {{org}}. Please clear it today.') returning id into t_firm;
  insert into message_templates (org_id, name, purpose, language, body) values
    (v_org, 'Invoice copy', 'invoice', 'te', '{{org}}: బిల్లు {{invoice_no}} ₹{{amount}} ({{items}}) పంపబడింది.') returning id into t_invoice;
  insert into message_templates (org_id, name, purpose, language, body) values
    (v_org, 'Receipt thanks', 'custom', 'te', 'ధన్యవాదాలు {{name}}! రసీదు {{receipt_no}} ₹{{amount}}. మిగిలిన బకాయి ₹{{outstanding}}.') returning id into t_receipt;
  insert into message_templates (org_id, name, purpose, language, body) values
    (v_org, 'Order received', 'order_ack', 'en', 'Thanks {{name}}, your order {{invoice_no}} ({{items}}) for Rs {{amount}} is being packed.') returning id into t_ack;
  insert into message_templates (org_id, name, purpose, language, body) values
    (v_org, 'New stock', 'new_stock', 'te', '{{name}} గారు, {{item}} మళ్ళీ స్టాక్ లో ఉంది. ఆర్డర్ చేయండి!') returning id into t_stock;
  insert into message_templates (org_id, name, purpose, language, body) values
    (v_org, 'Catalog', 'catalog', 'te', '{{org}} కొత్త కేటలాగ్ {{catalog}} జతచేయబడింది.') returning id into t_catalog;

  assert render_template('Hi {{name}}, {{x}}', '{"name":"Ravi"}') = 'Hi Ravi, {{x}}', 'unknown placeholders stay visible';

  -- ===== an old bill so there is something to remind about =====
  v_inv := save_invoice(jsonb_build_object('customer_id', v_a, 'invoice_date', current_date - 70, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');

  -- ===== queue_message honours opt-out and missing mobiles =====
  assert queue_message(jsonb_build_object('customer_id', v_b, 'purpose', 'custom', 'body', 'hello')) is null, 'opted-out customer must not be queued';
  assert queue_message(jsonb_build_object('customer_id', v_c, 'purpose', 'custom', 'body', 'hello')) is null, 'customer without a mobile must not be queued';
  v_id := send_custom_message(v_a, 'Namaste {{name}}, outstanding {{outstanding}}');
  select body, to_number into r from message_log where id = v_id;
  assert r.to_number = '9849686746', format('mobile normalised: %s', r.to_number);
  assert r.body = 'Namaste {{name}}, outstanding {{outstanding}}', 'a free-text body is sent as typed';
  v_id := queue_message(jsonb_build_object('customer_id', v_a, 'purpose', 'payment_reminder'));
  select body into s from message_log where id = v_id;
  assert s like 'నమస్తే P. SRINIVAS (MCL), JYOTHI FOODS బకాయి ₹2,688.00%', format('telugu default for a te customer: %s', s);
  delete from message_log where customer_id = v_a;

  -- ===== reminder ladder: gentle at 7 days, firm at 30 =====
  insert into reminder_rules (org_id, name, template_id, min_outstanding, overdue_days, repeat_every_days) values (v_org, 'Gentle', t_gentle, 1, 7, 7) returning id into r_gentle;
  insert into reminder_rules (org_id, name, template_id, min_outstanding, overdue_days, repeat_every_days) values (v_org, 'Firm', t_firm, 1, 30, 7) returning id into r_firm;
  select count(*) into n from reminder_recipients(r_gentle); assert n = 0, 'a 60-day overdue customer belongs to the firm rule, not the gentle one';
  select * into r from reminder_recipients(r_firm);
  assert r.customer_id = v_a and r.overdue_days = 60 and r.due and r.outstanding = 2688, format('firm recipient: %s', to_jsonb(r));
  j := run_reminder_rule(r_firm, true);
  assert (j->>'queued')::int = 1 and (j->>'dry_run')::boolean, format('dry run %s', j);
  select count(*) into n from message_log where rule_id = r_firm; assert n = 0, 'dry run must not queue';
  j := run_reminder_rule(r_firm, false);
  assert (j->>'queued')::int = 1, format('run %s', j);
  select body, purpose::text, status::text into r from message_log where rule_id = r_firm;
  assert r.body = 'Dear P. SRINIVAS (MCL), Rs 2,688.00 is overdue by 60 days at JYOTHI FOODS. Please clear it today.', format('reminder body: %s', r.body);
  assert r.purpose = 'payment_reminder' and r.status = 'queued';
  j := run_reminder_rule(r_firm, false);
  assert (j->>'queued')::int = 0 and (j->>'candidates')::int = 1 and j->'skipped'->0->>'reason' like 'reminded%', format('no repeat inside 7 days: %s', j);
  -- the gentle rule alone would take them once the firm rule is switched off
  update reminder_rules set is_active = false where id = r_firm;
  select count(*) into n from reminder_recipients(r_gentle); assert n = 1, 'gentle rule picks up when firm is off';
  update reminder_rules set is_active = true where id = r_firm;

  -- ===== transactional: invoice copy on dispatch, receipt thanks =====
  insert into transaction_message_settings (org_id, doc_type, is_enabled, template_id) values (v_org, 'invoice', true, t_invoice), (v_org, 'receipt', true, t_receipt), (v_org, 'order_ack', true, t_ack);
  perform set_invoice_status(v_inv, 'dispatched');
  select body into s from message_log where ref_table = 'invoices' and ref_id = v_inv and purpose = 'invoice';
  assert s like 'JYOTHI FOODS: బిల్లు % ₹2,688.00 (8 × 2) పంపబడింది.', format('invoice copy: %s', s);
  v_id := save_receipt(jsonb_build_object('customer_id', v_a, 'receipt_date', current_date), jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 688)));
  select body into s from message_log where ref_table = 'receipts' and ref_id = v_id;
  assert s like 'ధన్యవాదాలు P. SRINIVAS (MCL)! రసీదు % ₹688.00. మిగిలిన బకాయి ₹2,000.00.', format('receipt thanks: %s', s);
  -- with the switch off nothing is queued and the document still saves
  update transaction_message_settings set is_enabled = false where doc_type = 'receipt';
  perform save_receipt(jsonb_build_object('customer_id', v_a, 'receipt_date', current_date), jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 100)));
  select count(*) into n from message_log where ref_table = 'receipts'; assert n = 1, 'switch off = no message';

  -- ===== new stock broadcast: purchase lifts item 8 above 5 boxes =====
  -- the only sale is 70 days old: a 60-day lookback finds nobody, 90 finds the one buyer
  insert into new_stock_rules (org_id, item_id, threshold_boxes, lookback_days, template_id) values (v_org, v_item, 5, 60, t_stock);
  perform save_purchase(jsonb_build_object('location_id', v_loc, 'bill_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 320, 'uom_id', v_uom, 'rate', 30)));
  select id into v_bc from broadcasts where kind = 'new_stock';
  select count(*) into n from broadcast_recipients(v_bc); assert n = 0, format('70-day-old buyer is outside a 60-day lookback: %s', n);
  delete from broadcasts where id = v_bc;
  perform save_purchase(jsonb_build_object('location_id', v_loc, 'bill_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 32, 'uom_id', v_uom, 'rate', 30)));
  select count(*) into n from broadcasts where kind = 'new_stock'; assert n = 0, 'already above threshold: no broadcast';
  update new_stock_rules set lookback_days = 90 where item_id = v_item;
  -- sell it back below the threshold, then restock
  perform set_invoice_status(save_invoice(jsonb_build_object('customer_id', v_a, 'invoice_date', current_date - 70, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 9, 'rate', 42))), 'confirmed');
  perform save_purchase(jsonb_build_object('location_id', v_loc, 'bill_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 320, 'uom_id', v_uom, 'rate', 30)));
  select * into r from v_broadcasts where kind = 'new_stock';
  assert r.item_id = v_item and r.status = 'pending' and r.template_id = t_stock, format('broadcast created: %s', to_jsonb(r));
  v_bc := r.id;
  select count(*) into n from broadcast_recipients(v_bc); assert n = 1, format('only the recent buyer with opt-in: %s', n);
  j := queue_broadcast(v_bc);
  assert (j->>'queued')::int = 1, format('queued %s', j);
  select body, purpose::text into r from message_log where broadcast_id = v_bc;
  assert r.body = 'P. SRINIVAS (MCL) గారు, 5/- HT. MYSOOR PAK(12) 32 మళ్ళీ స్టాక్ లో ఉంది. ఆర్డర్ చేయండి!' and r.purpose = 'new_stock', format('stock body: %s', r.body);
  perform save_purchase(jsonb_build_object('location_id', v_loc, 'bill_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 32, 'uom_id', v_uom, 'rate', 30)));
  select count(*) into n from broadcasts where kind = 'new_stock'; assert n = 1, 'already above threshold: no second broadcast';
  begin
    perform queue_broadcast(v_bc); raise exception 'should not re-queue';
  exception when others then assert sqlerrm like 'Broadcast is already queued%', sqlerrm; end;

  -- ===== catalog to a segment =====
  insert into catalogs (org_id, name, pdf_url, valid_to) values (v_org, 'Diwali 2026', 'https://example.test/catalog.pdf', current_date + 30) returning id into v_cat;
  v_bc := create_broadcast(jsonb_build_object('kind', 'catalog', 'catalog_id', v_cat, 'template_id', t_catalog, 'segment', jsonb_build_object('town', 'MACHARLA')));
  select count(*) into n from broadcast_recipients(v_bc); assert n = 1, 'town segment';
  j := queue_broadcast(v_bc);
  select body, payload->>'media_url' as media into r from message_log where broadcast_id = v_bc;
  assert r.body = 'JYOTHI FOODS కొత్త కేటలాగ్ Diwali 2026 జతచేయబడింది.' and r.media = 'https://example.test/catalog.pdf', format('catalog msg: %s', to_jsonb(r));
  v_bc := create_broadcast(jsonb_build_object('kind', 'custom', 'body', 'Shop closed tomorrow', 'segment', jsonb_build_object('route_id', v_route)));
  select count(*) into n from broadcast_recipients(v_bc); assert n = 1, 'route segment';

  -- ===== the sender (service role): claims, quiet hours, daily cap, status webhook =====
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  select count(*) into n from message_log where org_id = v_org and status = 'queued';
  assert n >= 4, format('queued so far %s', n);
  select count(*) into q from claim_queued_messages(v_org, 2);
  assert q = 2, format('claim honours the limit: %s', q);
  select id into v_id from message_log where org_id = v_org and status = 'queued' and attempts = 1 limit 1;
  update message_log set status = 'sent', provider_msg_id = 'wamid.1', sent_at = now() where id = v_id;
  assert mark_message_status('wamid.1', 'delivered'), 'known provider id';
  assert not mark_message_status('wamid.nope', 'delivered'), 'unknown provider id';
  assert mark_message_status('wamid.1', 'sent'), 'late sent';
  select status::text into s from message_log where id = v_id; assert s = 'delivered', 'a late sent never undoes delivered';
  perform mark_message_status('wamid.1', 'read');
  select status::text, read_at is not null as has_read into r from message_log where id = v_id; assert r.status = 'read' and r.has_read;
  perform mark_message_status('wamid.1', 'failed', 'number not on WhatsApp');
  select status::text, error into r from message_log where id = v_id; assert r.status = 'failed' and r.error = 'number not on WhatsApp';
  update messaging_settings set daily_cap = 1 where org_id = v_org;
  select count(*) into q from claim_queued_messages(v_org, 10); assert q = 0, 'daily cap reached: nothing more today';
  update messaging_settings set daily_cap = 500, quiet_from = '00:00', quiet_to = '23:59' where org_id = v_org;
  select count(*) into q from claim_queued_messages(v_org, 10); assert q = 0, 'inside quiet hours: nothing';
  update messaging_settings set quiet_from = '00:00', quiet_to = '00:00' where org_id = v_org;

  -- ===== inbound: webhook matches customer by mobile, STOP opts out =====
  j := receive_inbound_order(jsonb_build_object('secret', v_secret, 'from', '+91 98496 86746', 'provider_ref', 'wa-1',
         'text', '2 box mysoor pak, 32 jar item 8, and 1 of code 999',
         'parsed_items', jsonb_build_array(
           jsonb_build_object('item_code', '8', 'qty', 2, 'uom', 'box', 'confidence', 0.95),
           jsonb_build_object('item_name', 'mysoor pak', 'qty', 32, 'uom', 'jar', 'confidence', 0.6),
           jsonb_build_object('item_code', '999', 'qty', 1, 'confidence', 0.9))));
  assert (j->>'matched')::boolean and (j->>'customer_id')::uuid = v_a, format('inbound %s', j);
  v_ord := (j->>'id')::uuid;
  j := receive_inbound_order(jsonb_build_object('secret', v_secret, 'from', '9849686746', 'provider_ref', 'wa-1', 'text', 'dup'));
  assert (j->>'id')::uuid = v_ord, 'same provider_ref = same order (idempotent webhook)';
  j := receive_inbound_order(jsonb_build_object('secret', v_secret, 'from', '9111111111', 'text', 'hello', 'source', 'call'));
  assert not (j->>'matched')::boolean and j->>'customer_id' is null, 'unknown number still lands in the queue';
  v_ord2 := (j->>'id')::uuid;
  begin
    perform receive_inbound_order(jsonb_build_object('secret', 'wrong', 'from', '9849686746', 'text', 'x')); raise exception 'should fail';
  exception when others then assert sqlerrm = 'Unknown webhook secret', sqlerrm; end;
  j := receive_inbound_order(jsonb_build_object('secret', v_secret, 'from', '9849686746', 'text', 'STOP'));
  assert (j->>'opted_out')::boolean; select whatsapp_opt_in into r from customers where id = v_a; assert not r.whatsapp_opt_in, 'STOP opts out';
  j := receive_inbound_order(jsonb_build_object('secret', v_secret, 'from', '9849686746', 'text', 'start'));
  select whatsapp_opt_in into r from customers where id = v_a; assert r.whatsapp_opt_in, 'START opts back in';

  -- ===== operator: matched lines, low confidence flagged, convert (never automatic) =====
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  select count(*) into n from v_inbound_orders where status = 'new'; assert n = 2, format('queue shows %s', n);
  select line_count into n from v_inbound_orders where id = v_ord; assert n = 3;
  select * into r from inbound_order_lines(v_ord) where idx = 1;
  assert r.item_id = v_item and r.match = 'code' and r.boxes = 2 and r.rate = 42 and not r.low_confidence, format('line 1: %s', to_jsonb(r));
  select * into r from inbound_order_lines(v_ord) where idx = 2;
  assert r.item_id = v_item and r.match = 'name' and r.boxes = 1 and r.low_confidence, format('line 2 (32 jars = 1 box, matched by name): %s', to_jsonb(r));
  select * into r from inbound_order_lines(v_ord) where idx = 3;
  assert r.item_id is null and r.match = 'none' and r.low_confidence, format('line 3: %s', to_jsonb(r));
  select count(*) into n from invoices where org_id = v_org; assert n = 2, 'nothing auto-invoiced (the two bills are the test''s own)';
  v_id := convert_inbound_order(v_ord, jsonb_build_object('customer_id', v_a, 'invoice_date', current_date, 'location_id', v_loc),
                                jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 3, 'rate', 42)));
  select status::text, invoice_id, invoice_no, handled_by_name into r from v_inbound_orders where id = v_ord;
  assert r.status = 'invoiced' and r.invoice_id = v_id and r.invoice_no is not null and r.handled_by_name = 'Owner', format('converted: %s', to_jsonb(r));
  select status::text, total into r from invoices where id = v_id; assert r.status = 'draft' and r.total = 4032, 'draft invoice for 3 boxes';
  select body into s from message_log where purpose = 'order_ack' and ref_id = v_id;
  assert s like 'Thanks P. SRINIVAS (MCL), your order % (8 × 3) for Rs 4,032.00 is being packed.', format('ack: %s', s);
  begin
    perform reject_inbound_order(v_ord, 'x'); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Order not found or already handled%', sqlerrm; end;
  v_ord3 := create_inbound_order(jsonb_build_object('customer_id', v_a, 'text', 'phone order: 5 boxes of 8', 'source', 'call'));
  perform reject_inbound_order(v_ord3, 'duplicate of WhatsApp order');
  select status::text, reject_reason into r from v_inbound_orders where id = v_ord3; assert r.status = 'rejected' and r.reject_reason like 'duplicate%';
  -- ===== the log view =====
  select count(*) into n from v_message_log where customer_name = 'P. SRINIVAS (MCL)'; assert n >= 5, format('log rows %s', n);

  -- ===== RLS: a sales_exec has no messaging module =====
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_sales, 'Sales', 'sales_exec');
  perform set_config('request.jwt.claim.sub', uid_sales::text, true);
  select count(*) into n from message_log; assert n = 0, 'sales_exec must not read the message log';
  select count(*) into n from inbound_orders; assert n = 0, 'sales_exec must not read inbound orders';
  begin
    perform get_messaging_settings(); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Messaging is not available%', sqlerrm; end;
  begin
    perform run_reminder_rule(r_firm, true); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Not allowed%', sqlerrm; end;
  begin
    select * into r from messaging_settings; assert r.org_id is null, 'settings table hidden from everyone signed in';
  exception when insufficient_privilege then null; end;

  reset role;
  raise notice 'OK: messaging — masked settings, te/en templates, opt-out honoured, reminder ladder (firm beats gentle, no repeat in 7 days), invoice/receipt/order messages, new-stock broadcast to recent buyers, catalog to a town, sender cap + quiet hours + status webhook, inbound by mobile with STOP/START, matched lines, human convert';
end $$;

rollback;
