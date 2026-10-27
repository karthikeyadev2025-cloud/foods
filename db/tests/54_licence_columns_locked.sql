-- ============================================================
-- DB acceptance test: the capped client cannot lift his own cap.
--
-- db/05 gave the owner an update policy on the whole orgs row so they could
-- edit their trade terms. The licence lives on that row, so one request —
-- "update orgs set license_plan = 'full'" — put a capped client back on Full.
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
  v_org uuid; uid uuid := gen_random_uuid(); v_msg text; n int; q text;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- a real licence first, or "clear the key" below would be setting null to
  -- null, which changes nothing and is rightly allowed
  perform issue_license(v_org, current_date + 365, 'Jyothi Foods, Macherla', 3, 'growth');
  -- the vendor caps the client and says why
  perform set_license_plan(v_org, 'growth');
  perform set_account_notice(v_org, 'Account on hold — balance outstanding.');

  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  assert my_plan() = 'growth', format('54.0 the client should be on growth, is %s', my_plan());

  -- ===== 54.1 the owner cannot put himself back on Full =====
  begin
    update orgs set license_plan = 'full' where id = v_org;
    raise exception '54.1 the client lifted his own cap';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%supplier of this software%', format('54.1 wrong reason: %s', v_msg);
  end;
  assert my_plan() = 'growth', format('54.1 the plan moved anyway: %s', my_plan());

  -- ===== 54.2 nor by the back doors =====
  begin
    update orgs set plan_full_until = current_date + 3650 where id = v_org;   -- a decade of trial
    raise exception '54.2 the client gave himself a plan trial';
  exception when sqlstate '42501' then null; end;

  begin
    update orgs set license_valid_till = current_date + 3650 where id = v_org;
    raise exception '54.2 the client extended his own licence';
  exception when sqlstate '42501' then null; end;

  begin
    update orgs set license_max_devices = 99 where id = v_org;
    raise exception '54.2 the client raised his own device limit';
  exception when sqlstate '42501' then null; end;

  begin
    update orgs set license_key = null where id = v_org;
    raise exception '54.2 the client cleared his own licence key';
  exception when sqlstate '42501' then null; end;

  begin
    update orgs set account_notice = null where id = v_org;
    raise exception '54.2 the client deleted the demand addressed to him';
  exception when sqlstate '42501' then null; end;

  assert my_plan() = 'growth', '54.2 something got through';
  select account_notice into q from orgs where id = v_org;
  assert q = 'Account on hold — balance outstanding.', format('54.2 the notice says %s', q);

  -- ===== 54.3 the business profile is still the owner's to edit =====
  update orgs set name = 'JYOTHI FOODS, MACHERLA', address = 'Main Road', phone = '9849686746'
   where id = v_org;
  get diagnostics n = row_count;
  assert n = 1, '54.3 the owner must still be able to edit the business profile';
  select name into q from orgs where id = v_org;
  assert q = 'JYOTHI FOODS, MACHERLA', format('54.3 the name did not save: %s', q);

  -- a row that touches both at once is refused whole, profile change included
  begin
    update orgs set address = 'Second Road', license_plan = 'full' where id = v_org;
    raise exception '54.3 a licence change smuggled in beside a profile change';
  exception when sqlstate '42501' then null; end;
  select address into q from orgs where id = v_org;
  assert q = 'Main Road', format('54.3 the refusal must roll back the lot; address is %s', q);

  -- ===== 54.4 the vendor is unaffected =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform set_license_plan(v_org, 'full');
  perform set_account_notice(v_org, null);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  assert my_plan() = 'full', format('54.4 the vendor could not restore the plan: %s', my_plan());
  select account_notice into q from orgs where id = v_org;
  assert q is null, format('54.4 the vendor could not clear the notice: %s', q);

  raise notice 'OK: a capped client cannot lift his own cap — not the plan, not a plan trial, not the licence date, not the device limit, not the key, and not the notice saying what he owes; a licence change smuggled in beside a profile change takes the profile change down with it; the owner still edits name, address and phone as before, and the vendor restores both plan and notice with one line each';
end $$;

rollback;
