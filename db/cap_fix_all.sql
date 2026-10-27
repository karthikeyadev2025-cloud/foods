-- ============================================================
-- JYOTHI FOODS ERP — CAP THE CLIENT, IN ONE PASTE
--
-- Everything the capping needs, in the order it needs it, safe to run twice.
-- Paste the WHOLE file into the Supabase SQL editor and run it once.
--
-- EDIT ONE LINE FIRST: the message near the bottom, marked "SET THIS". Put
-- your own phone number in it. That text is what the client reads on every
-- screen he has lost, and it is the only thing that turns a cap into a
-- payment rather than a phone call to you.
--
-- It does five things:
--   1. adds the account notice to the organisation
--   2. lets the vendor set that notice   (set_account_notice)
--   3. carries it out to the app          (license_status)
--   4. locks the licence columns so the client cannot lift his own cap
--   5. sets the notice and the plan, and prints what the client now has
--
-- The plan below is STARTER: billing, receipts, customers, items, stock on
-- hand, reports, setup and attendance. Everything else goes, purchases
-- included — so from the moment it runs the client cannot enter a supplier
-- bill, and his stock figures only fall. Change v_plan to 'growth' if that is
-- not what is wanted.
--
-- The Supabase editor runs the whole box as ONE transaction: if any line
-- fails, nothing at all is applied. So either it all lands or nothing does —
-- there is no half-capped state to untangle.
-- ============================================================

-- ------------------------------------------------------------
-- 1 & 2. The notice, and the vendor's way of setting it
-- ------------------------------------------------------------
alter table orgs add column if not exists account_notice text;

create or replace function set_account_notice(p_org uuid, p_notice text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if not is_service_call() then raise exception 'The account notice is set by the vendor only'; end if;
  update orgs set account_notice = nullif(btrim(coalesce(p_notice, '')), '') where id = p_org
  returning name into v_name;
  if v_name is null then raise exception 'Organisation not found'; end if;
  return coalesce((select account_notice from orgs where id = p_org), '(notice cleared)');
end $$;

revoke execute on function set_account_notice(uuid, text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 3. The app reads this on start-up and every half hour, so the notice
--    reaches the client without anybody reloading anything.
-- ------------------------------------------------------------
create or replace function license_status(p_device_id text default null, p_app_version text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s record; o orgs%rowtype; n int; known boolean := false;
        v_plan text; v_left integer;
begin
  if v_org is null then raise exception 'Not a member of any organisation'; end if;
  select * into o from orgs where id = v_org;
  select * into s from license_state(v_org);
  if p_device_id is not null then
    update license_devices set last_seen = now(), app_version = coalesce(p_app_version, app_version)
     where org_id = v_org and device_id = p_device_id;
    known := found;
  end if;
  select count(*) into n from license_devices where org_id = v_org;

  v_plan := case when o.plan_full_until is not null and o.plan_full_until >= current_date
                 then 'full' else o.license_plan end;
  v_left := case when o.plan_full_until is not null and o.plan_full_until >= current_date
                 then (o.plan_full_until - current_date) + 1 end;

  return jsonb_build_object('status', s.status, 'valid_till', s.valid_till, 'days_left', s.days_left, 'read_only', s.read_only,
                            'grace_days', s.grace_days, 'trial_days', s.trial_days, 'licensed_to', o.licensed_to,
                            'has_key', o.license_key is not null, 'devices', n, 'max_devices', o.license_max_devices,
                            'this_device_known', known, 'checked_at', now(),
                            'plan', v_plan, 'plan_name', plan_label(v_plan),
                            'paid_plan', o.license_plan, 'paid_plan_name', plan_label(o.license_plan),
                            'plan_full_until', o.plan_full_until,
                            'plan_trial_days_left', v_left,
                            'account_notice', o.account_notice,
                            'features', to_jsonb(plan_features(v_plan)),
                            'catalogue', (select jsonb_agg(to_jsonb(f)) from feature_catalogue() f));
end $$;

-- ------------------------------------------------------------
-- 4. The cap has to hold. db/05 gave the owner an update policy on the whole
--    orgs row so they could edit their trade terms, and the licence lives on
--    that row — so one request put a capped client back on Full. The licence
--    columns now refuse to change for anyone but the vendor. The owner keeps
--    the rest: name, address, phone, bank, trade terms, print settings.
-- ------------------------------------------------------------
create or replace function trg_orgs_licence_locked() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_service_call() then return new; end if;

  if new.license_key         is distinct from old.license_key
  or new.license_valid_till  is distinct from old.license_valid_till
  or new.license_plan        is distinct from old.license_plan
  or new.plan_full_until     is distinct from old.plan_full_until
  or new.licensed_to         is distinct from old.licensed_to
  or new.license_max_devices is distinct from old.license_max_devices
  or new.trial_days          is distinct from old.trial_days
  or new.license_grace_days  is distinct from old.license_grace_days
  or new.account_notice      is distinct from old.account_notice then
    raise exception 'The licence is set by the supplier of this software, not from here. Everything else on this screen can be changed as usual.'
      using errcode = '42501';
  end if;

  return new;
end $$;

drop trigger if exists t_orgs_licence_locked on orgs;   -- create trigger is not idempotent
create trigger t_orgs_licence_locked before update on orgs
  for each row execute function trg_orgs_licence_locked();

-- ------------------------------------------------------------
-- 5. Cap the client and tell him why
-- ------------------------------------------------------------
do $$
declare
  -- ======== SET THIS: your own words and your own phone number ========
  v_notice text := 'Account on hold — ₹2,60,000 outstanding. Call 98xxx xxxxx to restore.';
  v_plan   text := 'starter';         -- 'starter' or 'growth'
  -- ====================================================================
  v_org uuid; v_name text; n int; v_trial date;
begin
  if v_plan not in ('starter', 'growth') then
    raise exception 'This caps a client. Set v_plan to growth or starter — "%" is not a cap.', v_plan;
  end if;

  select count(*) into n from orgs;
  if n = 0 then raise exception 'There are no organisations in this database.'; end if;
  if n > 1 then
    raise exception 'There are % organisations here. This file caps the only one; name it by hand instead.', n;
  end if;
  select id, name, plan_full_until into v_org, v_name, v_trial from orgs;

  -- A running plan trial overrides license_plan entirely (db/24), so lowering
  -- the plan while one runs is a cap that reports success and changes nothing.
  if v_trial is not null and v_trial >= current_date then
    update orgs set plan_full_until = null where id = v_org;
    raise notice 'Plan trial ended (it ran to %), or the cap would not have bitten.', v_trial;
  end if;

  update orgs set license_plan = v_plan,
                  account_notice = nullif(btrim(v_notice), '')
   where id = v_org;

  raise notice 'Capped % to %, and told him why.', v_name, v_plan;
end $$;

-- ------------------------------------------------------------
-- What the client now has. Read this row: it is the whole answer.
-- ------------------------------------------------------------
select
  o.name                                            as organisation,
  case when o.plan_full_until is not null and o.plan_full_until >= current_date
       then 'full' else o.license_plan end          as plan_now,
  coalesce(o.account_notice, '(NOTHING — he is not being told why)') as he_is_told,
  case when exists (select 1 from pg_trigger t
                     where t.tgrelid = 'public.orgs'::regclass
                       and t.tgname = 't_orgs_licence_locked' and not t.tgisinternal)
       then 'locked — only you can change the licence'
       else 'NOT LOCKED — he can put himself back on Full' end as cap_holds,
  s.status                                          as licence,
  case when s.read_only then 'READ-ONLY' else 'can still write bills' end as writing,
  array_to_string(array(
    select f from unnest(plan_features('full')) f
     where f <> all (plan_features(
       case when o.plan_full_until is not null and o.plan_full_until >= current_date
            then 'full' else o.license_plan end))), ', ')          as he_has_lost
from orgs o
cross join lateral license_state(o.id) s;
