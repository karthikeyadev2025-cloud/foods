-- ============================================================
-- JYOTHI FOODS ERP — WHAT IS THE CLIENT ON RIGHT NOW?
--
-- Run this BEFORE capping anything. It changes nothing: every statement here
-- only reads. Send a screenshot of the result and the capping is one line.
--
-- There are three separate things that decide what a client gets, and they are
-- easy to confuse. All three are shown here:
--
--   license_plan      what the KEY bought: starter, growth or full. This is the
--                     cap. Lowering it hides screens; it deletes nothing.
--   plan_full_until   a plan TRIAL. While this date is today or later the org
--                     is treated as 'full' NO MATTER what license_plan says
--                     (db/24). Lowering the plan without ending the trial is a
--                     cap that does nothing at all.
--   licence state     trial / active / grace / expired / unlicensed. Expired
--                     and unlicensed are READ-ONLY: they can look and export,
--                     they cannot write a bill. This is the hammer, not a cap.
--
-- `effective plan` is what the client has in their hands this minute. If it
-- says full while `paid plan` says starter, a plan trial is running.
-- ============================================================

select
  o.name                                        as organisation,
  o.id                                          as org_id,
  o.licensed_to,

  -- what they get this minute
  case when o.plan_full_until is not null and o.plan_full_until >= current_date
       then 'full' else o.license_plan end      as effective_plan,
  o.license_plan                                as paid_plan,
  case when o.plan_full_until is null then 'no plan trial'
       when o.plan_full_until >= current_date
         then 'PLAN TRIAL RUNNING until ' || to_char(o.plan_full_until, 'DD-MM-YYYY')
              || ' — a lower plan will not bite until this is ended'
       else 'plan trial ended ' || to_char(o.plan_full_until, 'DD-MM-YYYY') end as plan_trial,

  -- the licence itself
  s.status                                      as licence,
  s.valid_till,
  s.days_left,
  case when s.read_only then 'READ-ONLY — cannot write bills' else 'can write' end as writing,

  -- Is the client being TOLD anything? A cap with no notice produces a support
  -- call, not a payment (db/63). This is the half nobody can see from the
  -- vendor's side without asking for it.
  coalesce(o.account_notice, '(nothing — the client is not being told why)') as account_notice,

  -- Can the client simply undo the cap? Until db/64 is run, the owner's update
  -- policy on orgs covers the licence columns, so one request puts them back
  -- on Full.
  case when to_regclass('public.orgs') is not null
             and exists (select 1 from pg_trigger t
                          where t.tgrelid = 'public.orgs'::regclass
                            and t.tgname = 't_orgs_licence_locked'
                            and not t.tgisinternal)
       then 'locked — only the vendor can change the licence'
       else 'NOT LOCKED — the client can set themselves back to Full. Run db/64.' end as cap_holds,

  -- what the effective plan unlocks, and what it does not
  array_to_string(plan_features(
    case when o.plan_full_until is not null and o.plan_full_until >= current_date
         then 'full' else o.license_plan end), ', ')  as unlocked,
  array_to_string(array(
    select f from unnest(plan_features('full')) f
     where f <> all (plan_features(
       case when o.plan_full_until is not null and o.plan_full_until >= current_date
            then 'full' else o.license_plan end))), ', ') as locked,

  -- devices and how busy the shop is, so nobody caps the wrong organisation
  (select count(*) from license_devices d where d.org_id = o.id) || ' of ' || o.license_max_devices as devices,
  (select count(*) from invoices  x where x.org_id = o.id) as invoices,
  (select count(*) from purchases x where x.org_id = o.id) as purchases,
  (select max(x.invoice_date) from invoices x where x.org_id = o.id) as last_billed
from orgs o
cross join lateral license_state(o.id) s
order by o.created_at;
