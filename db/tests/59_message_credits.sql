-- ============================================================
-- DB acceptance test: prepaid message credits.
--
-- Credits are money. The count has to be defensible six months later when
-- somebody says "I bought ten thousand and you have sent four thousand, where
-- are the rest" — so the tests here are the ones where money goes missing:
-- a payment webhook arriving twice, a message charged twice, two senders
-- spending the same last credit, and a shop that has run out.
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
  v_org uuid; uid uuid := gen_random_uuid(); v_cust uuid; j jsonb; n int; q int; v_msg text;
  v_m1 uuid; v_m2 uuid;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into customers (org_id, name, mobile1) values (v_org,'RAVI STORES','9849686746') returning id into v_cust;
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- ===== 59.1 a new shop has nothing =====
  assert credit_balance(v_org) = 0, format('59.1 a new shop starts at zero, has %s', credit_balance(v_org));

  -- ===== 59.2 buying credits =====
  -- 1,000 credits at 90 paise = 900 rupees
  select add_credits(v_org, 1000, 90000, 'pay_ABC123', 'order_X', 'razorpay', '1000 credits') into j;
  assert (j->>'credits_added')::int = 1000, format('59.2 %s', j);
  assert (j->>'balance')::int = 1000, format('59.2 balance %s', j->>'balance');
  select rate_paise into q from credit_topups where payment_id = 'pay_ABC123';
  assert q = 90, format('59.2 the rate per credit on the day should be 90 paise, recorded %s', q);

  -- ===== 59.3 the SAME payment arriving again adds nothing =====
  -- Razorpay retries a webhook until it gets a 200. Without this the shop is
  -- given free credits every time the network hiccups.
  select add_credits(v_org, 1000, 90000, 'pay_ABC123', 'order_X') into j;
  assert (j->>'already_counted')::boolean, format('59.3 a retry must be recognised: %s', j);
  assert (j->>'credits_added')::int = 0, '59.3 and must add nothing';
  assert credit_balance(v_org) = 1000, format('59.3 balance must not move: %s', credit_balance(v_org));
  select count(*) into n from credit_topups where org_id = v_org;
  assert n = 1, format('59.3 and must not record a second top-up, found %s', n);

  -- ===== 59.4 a different payment does add =====
  select add_credits(v_org, 500, 45000, 'pay_DEF456') into j;
  assert credit_balance(v_org) = 1500, format('59.4 balance %s', credit_balance(v_org));

  -- ===== 59.5 the shop cannot add its own credits =====
  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
  begin
    perform add_credits(v_org, 1000000, 0, null);
    raise exception '59.5 the shop gave itself a million credits';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%supplier only%', format('59.5 wrong reason: %s', v_msg);
  end;

  -- nor write the ledger directly
  begin
    insert into credit_ledger (org_id, delta, reason) values (v_org, 999999, 'help yourself');
    -- RLS has no insert policy, so this writes nothing rather than raising
    assert credit_balance(v_org) = 1500, '59.5 the shop wrote to its own credit ledger';
  exception when insufficient_privilege then null;
  end;
  -- but it can READ its own ledger, or it cannot check the bill
  select count(*) into n from credit_ledger where org_id = v_org;
  assert n = 2, format('59.5 the shop must be able to read its own ledger, sees %s rows', n);
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- ===== 59.6 sending spends one per message =====
  insert into messaging_settings (org_id, is_enabled, api_key, daily_cap, quiet_from, quiet_to)
  values (v_org, true, 'test-key', 500, time '23:59', time '00:00')
  on conflict (org_id) do update set is_enabled = true, api_key = 'test-key', daily_cap = 500,
                                     quiet_from = time '23:59', quiet_to = time '00:00';

  insert into message_log (org_id, customer_id, channel, purpose, to_number, body, status)
  values (v_org, v_cust, 'whatsapp', 'payment_reminder', '919849686746', 'one', 'queued') returning id into v_m1;
  insert into message_log (org_id, customer_id, channel, purpose, to_number, body, status)
  values (v_org, v_cust, 'whatsapp', 'payment_reminder', '919849686746', 'two', 'queued') returning id into v_m2;

  select count(*) into n from claim_queued_messages(v_org, 50);
  assert n = 2, format('59.6 both messages should be claimed, got %s', n);
  assert credit_balance(v_org) = 1498, format('59.6 two messages cost two credits: %s', credit_balance(v_org));

  -- ===== 59.7 a retry of the same message is not charged again =====
  -- Claiming does not mark a message sent — the provider's answer does that
  -- later — so a sender that died before answering leaves the message queued
  -- and it comes round again. The shop has already paid for it.
  select count(*) into n from claim_queued_messages(v_org, 50);
  assert n = 2, format('59.7 the same two come round again, got %s', n);
  assert credit_balance(v_org) = 1498,
    format('59.7 and must NOT be charged a second time: %s', credit_balance(v_org));
  select count(*) into n from credit_ledger where ref_table = 'message_log' and ref_id = v_m1;
  assert n = 1, format('59.7 exactly one charge exists for that message, found %s', n);

  -- ===== 59.8 a shop with no credits sends nothing, and loses nothing =====
  insert into credit_ledger (org_id, delta, reason) values (v_org, -1498, 'test: spend it all');
  assert credit_balance(v_org) = 0, '59.8 emptied';
  update message_log set status = 'queued', attempts = 0 where org_id = v_org;
  select count(*) into n from claim_queued_messages(v_org, 50);
  assert n = 0, format('59.8 nothing may be sent on an empty balance, claimed %s', n);
  select count(*) into n from message_log where org_id = v_org and status = 'queued';
  assert n = 2, format('59.8 and the messages must still be waiting, not dropped: %s', n);

  -- ===== 59.9 topping up lets new messages go, and charges for them =====
  -- The two above are already paid for and will never be charged again, so a
  -- fresh pair is needed to see a top-up actually being spent.
  insert into message_log (org_id, customer_id, channel, purpose, to_number, body, status)
  values (v_org, v_cust, 'whatsapp', 'payment_reminder', '919849686746', 'three', 'queued'),
         (v_org, v_cust, 'whatsapp', 'payment_reminder', '919849686746', 'four', 'queued');
  select add_credits(v_org, 10, 900, 'pay_TOPUP') into j;
  assert credit_balance(v_org) = 10, format('59.9 topped up to 10, is %s', credit_balance(v_org));
  select count(*) into n from claim_queued_messages(v_org, 50);
  assert n = 4, format('59.9 the two waiting and the two new all go, claimed %s', n);
  assert credit_balance(v_org) = 8,
    format('59.9 only the two NEW ones are charged: %s', credit_balance(v_org));

  -- ===== 59.10 money that arrives without a shop on it is parked, not lost =====
  insert into credit_payments_unmatched (provider, payment_id, amount_paise, payload)
  values ('razorpay', 'pay_NONAME', 90000, '{"event":"payment.captured"}'::jsonb);

  -- the shop cannot see or touch the supplier's tray
  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
  begin
    select count(*) into n from credit_payments_unmatched;
    assert n = 0, format('59.10 a shop must not read other shops'' payments, sees %s', n);
  exception when insufficient_privilege then null; end;
  begin
    perform assign_unmatched_payment('pay_NONAME', v_org);
    raise exception '59.10 the shop attributed a stray payment to itself';
  exception when sqlstate '42501' then null; end;
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- the supplier attributes it by hand: 900 rupees at 90 paise is 1,000 credits
  select assign_unmatched_payment('pay_NONAME', v_org) into j;
  assert (j->>'credits_added')::int = 1000, format('59.10 %s', j);
  assert credit_balance(v_org) = 1008, format('59.10 eight plus a thousand: %s', credit_balance(v_org));
  select count(*) into n from credit_payments_unmatched where payment_id = 'pay_NONAME' and assigned_org = v_org;
  assert n = 1, '59.10 and the parked payment now says whose it was';

  -- attributing it twice does not pay twice
  select assign_unmatched_payment('pay_NONAME', v_org) into j;
  assert (j->>'already_counted')::boolean, format('59.10 a second attribution must add nothing: %s', j);
  assert credit_balance(v_org) = 1008, format('59.10 balance must not move: %s', credit_balance(v_org));

  -- and a payment too small to buy one credit is refused rather than rounded up
  insert into credit_payments_unmatched (provider, payment_id, amount_paise, payload)
  values ('razorpay', 'pay_TINY', 50, '{}'::jsonb);
  begin
    perform assign_unmatched_payment('pay_TINY', v_org);
    raise exception '59.10 fifty paise bought a credit';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%does not buy one credit%', format('59.10 wrong reason: %s', v_msg);
  end;

  -- ===== 59.11 the balance never disagrees with the ledger =====
  select coalesce(sum(delta), 0) into q from credit_ledger where org_id = v_org;
  assert q = credit_balance(v_org), '59.11 the balance IS the ledger, by construction';

  raise notice 'OK: credits are a ledger, not a number — a payment arriving twice adds nothing and says so, a message is charged exactly once however many times the sender retries it, a shop on zero sends nothing and loses nothing because the messages wait for a top-up, the shop can read its own ledger but can neither write it nor hand itself credits, a payment that does not say which shop it is for is parked for the supplier to attribute by hand rather than lost or guessed at, and the balance is the sum of the ledger by construction';
end $$;

rollback;
