-- ============================================================
-- DB acceptance test: T12b voice calls on Hey Nikki. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_cust uuid; v_cust2 uuid; v_item uuid; v_route uuid; v_rule uuid; v_msg uuid; v_bc uuid; v_secret text;
  r record; n int; j jsonb;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into routes (org_id, name) values (v_org, 'GUNTUR LINE') returning id into v_route;
  insert into customers (org_id, name, town, mobile1, route_id, language) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746', v_route, 'te') returning id into v_cust;
  insert into customers (org_id, name, town, mobile1, route_id, language) values (v_org, 'RAVI STORES', 'GUNTUR', '9000000002', v_route, 'en') returning id into v_cust2;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate) values (v_org, '8', 'MYSOOR PAK', v_uom, v_pack, 32, 12, 42) returning id into v_item;
  perform set_invoice_status(save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date - 20, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42))), 'confirmed');
  perform set_invoice_status(save_invoice(jsonb_build_object('customer_id', v_cust2, 'invoice_date', current_date - 20, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42))), 'confirmed');
  -- quiet_from = quiet_to means never quiet. This test is about the voice switch and the
  -- retry ladder; without pinning it, every claim assertion below fails after 21:00 IST,
  -- which is a broken test rather than a finding.
  j := save_messaging_settings(jsonb_build_object('api_key', 'nk_test', 'is_enabled', true, 'voice_enabled', false, 'caller_number', '918000000000', 'call_attempts', 2, 'call_retry_minutes', 30, 'quiet_from', '00:00', 'quiet_to', '00:00'));
  assert (j->>'voice_enabled')::boolean = false and j->>'caller_number' = '918000000000' and (j->>'call_attempts')::int = 2, format('settings %s', j);
  v_secret := j->>'webhook_secret';   -- only the settings RPC hands the secret out; the table is closed to the browser

  -- templates: a WhatsApp text and a spoken script for the same purpose
  insert into message_templates (org_id, name, purpose, language, channel, body) values
    (v_org, 'Reminder (te)', 'payment_reminder', 'te', 'whatsapp', 'నమస్తే {{name}} గారు, బకాయి ₹{{outstanding}}.'),
    (v_org, 'Reminder call (te)', 'payment_reminder', 'te', 'ivr_call', 'నమస్కారం {{name}} గారు. {{org}} నుండి. మీ బకాయి {{outstanding}} రూపాయలు. ఈ వారంలో చెల్లిస్తే 1 నొక్కండి.'),
    (v_org, 'Order call (te)', 'custom', 'te', 'ivr_call', 'నమస్కారం {{name}} గారు. {{org}} నుండి. గత సారి {{last_items}} తీసుకున్నారు. ఈ వారం ఏమి కావాలో చెప్పండి.');

  -- ===== channel-aware template pick =====
  v_msg := queue_message(jsonb_build_object('customer_id', v_cust, 'purpose', 'payment_reminder'));
  select channel::text as ch, body into r from message_log where id = v_msg; assert r.ch = 'whatsapp' and r.body like 'నమస్తే%', format('text pick %s', to_jsonb(r));
  v_msg := queue_message(jsonb_build_object('customer_id', v_cust, 'purpose', 'payment_reminder', 'channel', 'ivr_call'));
  select channel::text as ch, body into r from message_log where id = v_msg; assert r.ch = 'ivr_call' and r.body like 'నమస్కారం%' and r.body like '%2,688.00%', format('script pick %s', to_jsonb(r));
  begin
    perform queue_message(jsonb_build_object('customer_id', v_cust, 'purpose', 'invoice', 'channel', 'ivr_call')); raise exception 'should fail';
  exception when others then assert sqlerrm like 'No active invoice call script%', sqlerrm; end;
  delete from message_log where org_id = v_org;

  -- ===== a reminder rule that calls =====
  insert into reminder_rules (org_id, name, overdue_days, channel, repeat_every_days) values (v_org, 'Call after a week', 5, 'ivr_call', 7) returning id into v_rule;
  j := run_reminder_rule(v_rule, false);
  assert (j->>'queued')::int = 2, format('two calls queued %s', j);
  select count(*) into n from message_log where org_id = v_org and channel = 'ivr_call' and status = 'queued'; assert n = 2;

  -- the sender: voice off → no calls claimed; on → claimed
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  select count(*) into n from claim_queued_messages(v_org, 50); assert n = 0, 'voice off: calls stay queued';
  update messaging_settings set voice_enabled = true where org_id = v_org;
  select count(*) into n from claim_queued_messages(v_org, 50); assert n = 2, 'voice on: both claimed';
  update message_log set status = 'sent', provider_msg_id = 'call-' || id::text, sent_at = now() where org_id = v_org;
  select id into v_msg from message_log where org_id = v_org and customer_id = v_cust;

  -- ===== call outcomes =====
  assert mark_call_result('call-' || v_msg::text, 'answered', null, '{}'::jsonb), 'known call';
  select status::text as st, call_status into r from message_log where id = v_msg; assert r.st = 'delivered' and r.call_status = 'answered', format('answered %s', to_jsonb(r));
  perform mark_call_result('call-' || v_msg::text, 'completed', 42, jsonb_build_object('dtmf', '1', 'recording_url', 'https://x/rec.mp3'));
  select status::text as st, call_duration, promised_on, call_result->>'note' as note, recording_url into r from v_message_log where id = v_msg;
  assert r.st = 'read' and r.call_duration = 42 and r.promised_on = current_date + 7 and r.note like 'Promised%' and r.recording_url = 'https://x/rec.mp3', format('completed %s', to_jsonb(r));
  select payment_promise_on, payment_promise_note into r from customers where id = v_cust; assert r.payment_promise_on = current_date + 7, 'promise on the customer';
  -- a promise holds the reminders back
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  select due, skip_reason into r from reminder_recipients(v_rule) where customer_id = v_cust; assert r.due = false and r.skip_reason like 'promised to pay by%', format('promise skip %s', to_jsonb(r));
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  -- the other customer did not answer: retried after the delay, then failed
  select id into v_msg from message_log where org_id = v_org and customer_id = v_cust2;
  perform mark_call_result('call-' || v_msg::text, 'no_answer', null, '{}'::jsonb);
  select status::text as st, attempts, not_before into r from message_log where id = v_msg;
  assert r.st = 'queued' and r.attempts = 1 and r.not_before > now() + interval '20 minutes', format('retry later %s', to_jsonb(r));
  select count(*) into n from claim_queued_messages(v_org, 50); assert n = 0, 'not before the retry delay';
  update message_log set not_before = now() - interval '1 minute' where id = v_msg;
  select count(*) into n from claim_queued_messages(v_org, 50); assert n = 1, 'claimed again after the delay';
  update message_log set status = 'sent' where id = v_msg;
  perform mark_call_result('call-' || v_msg::text, 'no_answer', null, '{}'::jsonb);
  select status::text as st, error into r from message_log where id = v_msg; assert r.st = 'failed' and r.error = 'no answer', format('final %s', to_jsonb(r));
  assert not mark_call_result('call-unknown', 'answered', null, '{}'::jsonb), 'unknown call ignored';

  -- ===== order-taking call campaign =====
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  v_bc := create_broadcast(jsonb_build_object('kind', 'order_call', 'segment', jsonb_build_object('route_id', v_route), 'note', 'Monday orders'));
  j := queue_broadcast(v_bc);
  assert (j->>'queued')::int = 2, format('two order calls %s', j);
  select channel::text as ch, purpose::text as pu, body, payload->>'kind' as kind into r from message_log where broadcast_id = v_bc and customer_id = v_cust;
  assert r.ch = 'ivr_call' and r.pu = 'custom' and r.kind = 'order_call' and r.body like '%MYSOOR PAK 2%', format('order call %s', to_jsonb(r));
  select id into v_msg from message_log where broadcast_id = v_bc and customer_id = v_cust;
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  update message_log set status = 'sent', provider_msg_id = 'call-' || v_msg::text where id = v_msg;

  -- Nikki's bot heard the order and posts it back with our message id
  j := receive_inbound_order(jsonb_build_object('secret', v_secret, 'client_ref', v_msg, 'transcript', 'రెండు బాక్సులు మైసూర్ పాక్', 'parsed_items', jsonb_build_array(jsonb_build_object('item_name', 'MYSOOR PAK', 'qty', 2)), 'duration', 65, 'language', 'te', 'audio_url', 'https://x/order.mp3'));
  assert (j->>'matched')::boolean and (j->>'message_id')::uuid = v_msg, format('inbound linked %s', j);
  select source::text as src, customer_id, message_id, call_duration, campaign_kind, campaign_note into r from v_inbound_orders where id = (j->>'id')::uuid;
  assert r.src = 'call' and r.customer_id = v_cust and r.message_id = v_msg and r.call_duration = 65 and r.campaign_kind = 'order_call' and r.campaign_note = 'Monday orders', format('inbound row %s', to_jsonb(r));
  select status::text as st, call_result->>'order_id' as oid, transcript into r from v_message_log where id = v_msg;
  assert r.st = 'read' and r.oid = j->>'id' and r.transcript like 'రెండు%', format('call marked read with the order %s', to_jsonb(r));
  -- a plain inbound WhatsApp order still works without any call
  j := receive_inbound_order(jsonb_build_object('secret', v_secret, 'from', '9000000002', 'text', '1 box mysoor pak'));
  select source::text as src, message_id into r from v_inbound_orders where id = (j->>'id')::uuid; assert r.src = 'whatsapp' and r.message_id is null;

  reset role;
  raise notice 'OK: voice — call scripts picked by channel (never a text for a call), reminder rule rings, voice switch gates the sender, answered → completed with key 1 sets a promise that holds reminders, no-answer retries after the delay then fails, order-call campaign rings a route with last items, the bot''s order comes back linked to the call';
end $$;

rollback;
