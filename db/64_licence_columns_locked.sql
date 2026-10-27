-- ============================================================
-- JYOTHI FOODS ERP — 64: THE CLIENT COULD UN-CAP HIMSELF
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- Capping a plan is enforced everywhere it is read (db/21): can_view, can_edit,
-- restrictive policies on the feature tables, require_feature in the definer
-- functions. All of it correct, and all of it beside the point, because the
-- plan itself sat on a row the client was allowed to write.
--
-- db/05 gave the owner an update policy on orgs so they could edit their own
-- trade terms — reasonable, and it covers EVERY column of that row, licence
-- included. So an owner signed into the app, with the anon key the app already
-- ships, could send one request:
--
--     update orgs set license_plan = 'full';
--
-- and be back on Full. Checked, not supposed: the update reported 1 row and
-- my_plan() returned 'full' immediately afterwards. A cap that the capped
-- party can lift is not a cap.
--
-- The licence columns now refuse to change unless the caller is the vendor —
-- a call with no signed-in user, which is what the SQL editor is and what the
-- service role is. The owner keeps every other column: name, address, phone,
-- FSSAI, bank details, trade terms, breakage percentage, print settings. Only
-- what was bought, until when, on how many machines, and what is owed, are
-- taken out of their hands.
--
-- A trigger rather than a narrower policy, because a policy cannot see which
-- columns changed, and splitting the licence onto its own table would break
-- every function that reads orgs%rowtype.
-- ============================================================

create or replace function trg_orgs_licence_locked() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- The vendor is a call with no signed-in user: the Supabase SQL editor, the
  -- service role, and the security-definer functions called from them.
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
