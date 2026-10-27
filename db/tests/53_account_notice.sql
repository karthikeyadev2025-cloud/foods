-- ============================================================
-- DB acceptance test: the vendor's message about the account.
--
-- A cap that tells the client nothing produces a support call, not a payment.
-- The notice has to reach the client, and the client must not be able to
-- delete the demand addressed to them.
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
  v_org uuid; uid uuid := gen_random_uuid(); j jsonb; v_msg text; v_out text;
  k constant text := 'Account on hold — ₹2,60,000 outstanding. Call 98xxx xxxxx to restore.';
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  -- the vendor is a call with no signed-in user at all, which is what the
  -- Supabase SQL editor is; `reset role` alone leaves the JWT claim in place
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- ===== 53.1 nothing to say by default =====
  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
  select license_status() into j;
  assert j ? 'account_notice', '53.1 license_status must carry account_notice';
  assert j->>'account_notice' is null, format('53.1 a new org should have no notice, has %s', j->>'account_notice');
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- ===== 53.2 the vendor sets it, and the client sees it =====
  v_out := set_account_notice(v_org, k);
  assert v_out = k, format('53.2 set_account_notice returned %s', v_out);

  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
  select license_status() into j;
  assert j->>'account_notice' = k, format('53.2 the client should see the notice, sees %s', j->>'account_notice');

  -- ===== 53.3 the client cannot set or clear it =====
  begin
    perform set_account_notice(v_org, 'all paid, thanks');
    raise exception '53.3 the client cleared the demand addressed to them';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%vendor only%', format('53.3 wrong reason: %s', v_msg);
  end;
  begin
    update orgs set account_notice = null where id = v_org;
    -- orgs is never writable from the client (db/03): no policy, so this
    -- updates no rows rather than raising
    select license_status() into j;
    assert j->>'account_notice' = k, '53.3 the client wrote to orgs directly and cleared the notice';
  exception when insufficient_privilege then null;
  end;
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- ===== 53.4 blank is the same as nothing, so it never shows an empty box =====
  perform set_account_notice(v_org, '   ');
  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
  select license_status() into j;
  assert j->>'account_notice' is null, '53.4 whitespace should clear the notice, not show an empty box';
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- ===== 53.5 the day the money arrives, one line each way =====
  perform set_account_notice(v_org, k);
  perform set_license_plan(v_org, 'growth');
  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
  select license_status() into j;
  assert j->>'plan' = 'growth' and j->>'account_notice' = k, '53.5 capped, and told why';
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  perform set_license_plan(v_org, 'full');
  perform set_account_notice(v_org, null);
  perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
  select license_status() into j;
  assert j->>'plan' = 'full' and j->>'account_notice' is null,
    format('53.5 after paying: plan %s, notice %s', j->>'plan', j->>'account_notice');
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- ===== 53.6 an organisation that is not there =====
  begin
    perform set_account_notice(gen_random_uuid(), 'x');
    raise exception '53.6 a notice was set on nothing';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%not found%', format('53.6 wrong reason: %s', v_msg);
  end;

  raise notice 'OK: the vendor can put one line on a client''s account and the client sees it on every locked screen and on Setup → Licence; the client can neither set it nor clear it, blank is the same as nothing, and on the day the money arrives the plan and the notice each come back with one line';
end $$;

rollback;
