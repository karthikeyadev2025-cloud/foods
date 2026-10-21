-- ============================================================
-- JYOTHI FOODS ERP — PHASE 1: CAP THE PLAN
--
-- Run db/cap_check.sql first and read what it says. This file changes the
-- client's plan and nothing else. It is the mildest of the three caps:
--
--   PHASE 1 (this file)  lower the plan. Locked screens disappear from the
--                        menu and the database refuses to write them, but
--                        every row the client already made stays exactly where
--                        it is. One line puts it back. The shop keeps trading.
--
--   PHASE 2              lower the device limit, so it runs on fewer machines.
--
--   PHASE 3              let the licence lapse: read-only. They can look and
--                        export; they cannot write a bill. This stops the shop
--                        trading and is not in this file on purpose.
--
-- WHAT THE CLIENT LOSES, by plan:
--
--   growth   loses WhatsApp and voice messaging, batches and barcodes, the
--            print designer, backup, audit, route profit, incentives, the
--            driver's phone app and the desktop app.
--   starter  loses all of that AND purchases, returns, payments, production,
--            vans, quotations, orders, challans and price lists. Billing and
--            collection only.
--
-- Starter would stop them entering purchases — and their stock is already
-- short because purchases and production are not being recorded. Growth is the
-- cap that bites without making the books worse.
--
-- WHAT THE CLIENT SEES: the locked screens are gone from the menu at the next
-- page load, and Setup → Licence names the plan they are on. Nothing warns
-- them in advance; tell them yourself before running this.
--
-- TO RUN: set the two values below and run the whole file. It ends with the
-- same reading db/cap_check.sql gives, so the result IS the proof it worked.
-- ============================================================

do $$
declare
  -- ---- SET THESE TWO ----
  v_plan text := 'growth';   -- 'growth' or 'starter'
  v_org  uuid := null;       -- null = the only organisation; otherwise paste its id
  -- -----------------------
  v_name text; v_was text; v_trial date; n int;
begin
  if v_plan not in ('starter', 'growth') then
    raise exception 'Phase 1 lowers the plan. Set v_plan to growth or starter — "%" is not a cap.', v_plan;
  end if;

  -- Never guess which organisation. If there is more than one, say so and stop.
  if v_org is null then
    select count(*) into n from orgs;
    if n = 0 then raise exception 'There are no organisations in this database.'; end if;
    if n > 1 then
      raise exception 'There are % organisations here. Run db/cap_check.sql, then paste the right org_id into v_org.', n;
    end if;
    select id into v_org from orgs;
  end if;

  select name, license_plan, plan_full_until into v_name, v_was, v_trial from orgs where id = v_org;
  if v_name is null then raise exception 'No organisation with that id.'; end if;

  -- A running plan trial overrides license_plan entirely (db/24): lowering the
  -- plan while it runs is a cap that does nothing until the trial lapses. End
  -- it, or this file would report success and change what the client sees not
  -- one bit.
  if v_trial is not null and v_trial >= current_date then
    update orgs set plan_full_until = null where id = v_org;
    raise notice 'Plan trial ended (it ran to %), or the cap would not have bitten.', v_trial;
  end if;

  update orgs set license_plan = v_plan where id = v_org;

  raise notice 'Capped % : % -> %', v_name, v_was, v_plan;
end $$;

-- The reading after. `effective_plan` is what the client has in their hands
-- this minute — if it still says full, something above did not take.
select
  o.name                                        as organisation,
  case when o.plan_full_until is not null and o.plan_full_until >= current_date
       then 'full' else o.license_plan end      as effective_plan,
  o.license_plan                                as paid_plan,
  coalesce(to_char(o.plan_full_until, 'DD-MM-YYYY'), 'no plan trial') as plan_trial,
  s.status                                      as licence,
  case when s.read_only then 'READ-ONLY' else 'can write' end as writing,
  array_to_string(plan_features(
    case when o.plan_full_until is not null and o.plan_full_until >= current_date
         then 'full' else o.license_plan end), ', ')  as unlocked,
  array_to_string(array(
    select f from unnest(plan_features('full')) f
     where f <> all (plan_features(
       case when o.plan_full_until is not null and o.plan_full_until >= current_date
            then 'full' else o.license_plan end))), ', ') as now_locked
from orgs o
cross join lateral license_state(o.id) s
order by o.created_at;
