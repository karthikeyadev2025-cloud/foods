-- ============================================================
-- JYOTHI FOODS ERP — 24: A TASTE OF THE WHOLE THING
--
-- A client who has paid for Starter still gets a few days of everything, so
-- they can see what Growth and Full actually do before deciding. This is not
-- the licence trial in 18_licensing.sql and must not be confused with it:
--
--   licence trial   no key at all. Ends in READ-ONLY — no new invoices. It is
--                   the "you have not paid" state.
--   plan trial      this file. The licence is active and stays active; only
--                   the FEATURE SET steps down, on a date, to what was bought.
--
-- Using the licence trial for this would stop the client billing on day 11,
-- which is the opposite of the intent.
--
-- Nothing here schedules a job. my_plan() simply reads the date every time,
-- so the step-down happens on its own and cannot be forgotten.
-- ============================================================

alter table orgs
  /** Everything is unlocked until the end of this day. Null = no plan trial. */
  add column if not exists plan_full_until date;

/**
 * The plan in force right now.
 *
 * During a plan trial this is 'full' whatever was paid for; afterwards it is
 * license_plan again, and the client keeps every row they made in the meantime —
 * the locked screens hide, they do not delete. The service role is never capped.
 */
create or replace function my_plan() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select case when o.plan_full_until is not null and o.plan_full_until >= current_date
                 then 'full' else o.license_plan end
       from orgs o where o.id = my_org_id()),
    'starter');
$$;

/**
 * Start (or extend, or cancel) the plan trial. Vendor only, like issue_license:
 * a client who could call this could hand themselves Full for a decade.
 * p_days = 0 ends it now.
 */
create or replace function start_plan_trial(p_org uuid, p_days integer default 10) returns date
language plpgsql security definer set search_path = public as $$
declare v_until date;
begin
  if not is_service_call() then raise exception 'Plan trials are set by the vendor only'; end if;
  if p_days < 0 then raise exception 'Days cannot be negative'; end if;
  v_until := case when p_days = 0 then null else current_date + p_days - 1 end;
  update orgs set plan_full_until = v_until where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
  return v_until;
end $$;

revoke execute on function start_plan_trial(uuid, integer) from public, anon, authenticated;

/**
 * license_status() gains three fields so the screen can say what is happening
 * rather than silently showing Full to a Starter client:
 *
 *   plan            what is in force NOW — 'full' during the trial
 *   paid_plan       what the key actually bought, and what it drops back to
 *   plan_trial_days_left  null when there is no trial running
 */
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
                            'features', to_jsonb(plan_features(v_plan)),
                            'catalogue', (select jsonb_agg(to_jsonb(f)) from feature_catalogue() f));
end $$;

-- ------------------------------------------------------------
-- How to use it, from the SQL Editor (vendor only):
--
--   -- issue what they paid for, then open everything for ten days
--   select issue_license((select id from orgs limit 1), '2027-09-30', 'Jyothi Foods, Guntur', 3, 'starter');
--   select start_plan_trial((select id from orgs limit 1), 10);
--
--   -- see where it stands
--   select name, license_plan as paid, plan_full_until from orgs;
--
--   -- end it early, or extend it
--   select start_plan_trial((select id from orgs limit 1), 0);
--   select start_plan_trial((select id from orgs limit 1), 20);
-- ------------------------------------------------------------
