-- ============================================================
-- DB acceptance test: the plan trial — everything for a few days, then
-- back to what was paid for, with the licence active throughout. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
revoke execute on function issue_license(uuid, date, text, integer, text) from authenticated;
revoke execute on function start_plan_trial(uuid, integer) from authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_cust uuid; v_item uuid; v_cash uuid; v_key text;
  j jsonb; n int;
  uid_owner uuid := gen_random_uuid();
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
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table) values (v_org, v_item, v_loc, 'opening', current_date, 3200, 'test');

  -- ===== the vendor sells Starter, then opens everything for ten days =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  v_key := issue_license(v_org, current_date + 365, 'Jyothi Foods, Guntur', 3, 'starter');
  assert start_plan_trial(v_org, 10) = current_date + 9, 'ten days counting today';
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;

  j := license_status();
  assert j->>'status' = 'active' and (j->>'read_only')::boolean = false, format('licence active throughout %s', j);
  assert j->>'plan' = 'full' and j->>'plan_name' = 'Full', format('in force now %s', j);
  assert j->>'paid_plan' = 'starter' and j->>'paid_plan_name' = 'Starter', format('what they actually bought %s', j);
  assert (j->>'plan_trial_days_left')::int = 10, format('days left %s', j->>'plan_trial_days_left');

  -- everything really is open: a Full-only feature answers
  assert has_feature('messaging') and has_feature('owner') and has_feature('attendance') and has_feature('purchases');
  insert into message_templates (org_id, name, purpose, language, channel, body) values (v_org, 'Reminder', 'payment_reminder', 'te', 'whatsapp', 'బకాయి {{outstanding}}');
  perform save_quotation(jsonb_build_object('customer_id', v_cust, 'quote_date', current_date), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  select count(*) into n from message_templates; assert n = 1, 'made during the plan trial';

  -- ===== the last day is still open =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  update orgs set plan_full_until = current_date where id = v_org;
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  j := license_status();
  assert j->>'plan' = 'full' and (j->>'plan_trial_days_left')::int = 1, format('the last day counts %s', j);

  -- ===== the day after, it is Starter — and the licence is still active =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  update orgs set plan_full_until = current_date - 1 where id = v_org;
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;

  j := license_status();
  assert j->>'status' = 'active' and (j->>'read_only')::boolean = false,
         format('the step-down must not stop them billing %s', j);
  assert j->>'plan' = 'starter' and j->>'paid_plan' = 'starter', format('back to what was paid %s', j);
  assert j->>'plan_trial_days_left' is null, 'no trial running any more';
  assert j->'features' = '["core", "attendance"]'::jsonb, format('starter features %s', j->'features');
  -- attendance is a Starter feature, so it survives the step-down; the rest does not
  assert has_feature('core') and has_feature('attendance');
  assert not has_feature('messaging') and not has_feature('purchases') and not has_feature('payments');

  -- billing and collection carry on exactly as before
  perform set_invoice_status(save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42))), 'confirmed');
  perform save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date), jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 500)));

  -- nothing made during the trial was destroyed; the module simply hides it
  select count(*) into n from message_templates; assert n = 0, 'a locked module hides its rows, it does not delete them';
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  select count(*) into n from message_templates where org_id = v_org;
  assert n = 1, format('the template is still on disk, found %s', n);

  -- ===== the vendor can end it early, extend it, or open it again =====
  assert start_plan_trial(v_org, 0) is null, 'zero days ends it';
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  assert (license_status()->>'plan') = 'starter';
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  assert start_plan_trial(v_org, 20) = current_date + 19, 'and it can be opened again';
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  assert (license_status()->>'plan') = 'full';

  -- ===== a client cannot give themselves one =====
  begin
    perform start_plan_trial(v_org, 3650);
    assert false, 'only the vendor may start a plan trial';
  exception when others then null; end;

  -- ===== paying for real ends the distinction: paid_plan catches up =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform start_plan_trial(v_org, 0);
  perform set_license_plan(v_org, 'growth');
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  j := license_status();
  assert j->>'plan' = 'growth' and j->>'paid_plan' = 'growth', format('upgraded for real %s', j);
  assert has_feature('purchases') and has_feature('attendance') and not has_feature('messaging'),
         format('growth features %s', j->'features');

  reset role;
  raise notice 'OK: plan trial — Starter sold, everything open for ten days with the licence active, the last day counts, the day after steps down to Starter without stopping the billing, rows made in the trial survive hidden, the vendor can end or extend it, a client cannot grant one, and paying for real supersedes it';
end $$;

rollback;
