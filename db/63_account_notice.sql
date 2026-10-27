-- ============================================================
-- JYOTHI FOODS ERP — 63: TELL THE CLIENT WHY, AND WHAT TO PAY
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- Capping a plan already works and the database enforces it (db/21). What was
-- missing is the other half of capping for money: the client is told nothing.
--
-- A locked screen today says "WhatsApp & calls is not in your licence. You are
-- on Growth. This is included in Full." True, and useless to a shopkeeper who
-- had it yesterday. He does not conclude "I should pay the balance" — he
-- concludes the software is broken, and rings to say so. A cap that produces
-- a support call instead of a payment has cost the vendor twice.
--
-- So the vendor gets one line of text on the organisation, shown wherever the
-- cap bites:
--
--   select set_account_notice('<org id>',
--     'Account on hold — ₹2,60,000 outstanding. Call 98xxx xxxxx to restore.');
--
-- It appears on every locked screen and at the top of Setup → Licence. It is
-- plain text the vendor writes, in whatever words and language suit the client;
-- the system never writes it and never guesses an amount. Clearing it is
-- set_account_notice('<org id>', null), and that is what gets run the day the
-- money arrives, alongside set_license_plan(..., 'full').
--
-- It does not lock anything by itself, and it is not shown when there is
-- nothing to say. A notice with a full plan is just a message — which is also
-- useful: "Renewal due 30-11-2026" a fortnight before the key lapses.
-- ============================================================

alter table orgs add column if not exists account_notice text;

comment on column orgs.account_notice is
  'Vendor''s message to this client, shown on locked screens and Setup → Licence. Null means nothing to say.';

/**
 * Vendor only, like issue_license and set_license_plan: a client who could set
 * this could delete the demand for payment addressed to them.
 */
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
-- license_status gains the notice. Everything else it returned is unchanged —
-- the screen reads this on start-up and every half hour, so the notice reaches
-- the client within the half hour without anybody reloading anything.
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
