-- ============================================================
-- JYOTHI FOODS ERP — 69: A SHOP CAN ALWAYS GET ITS OWN DATA OUT
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "Backup not working." It was not broken. Backup sits inside Owner control,
-- which db/21 made a FULL-plan feature, so a shop capped to Starter has no
-- Backup tab at all — not an error, not a message, simply nothing there. The
-- screen was doing exactly what it was told.
--
-- What it was told was wrong, and this corrects the rule rather than the
-- symptom. A licence decides what a shop can DO with the software. It must
-- not decide whether they can have a copy of their own invoices. Every row in
-- that database was typed by them, and the day they are most likely to want
-- it out — the account is in dispute, the plan is capped, they are thinking
-- of leaving — is precisely the day the old rule took it away. Holding a
-- customer's books to ransom is not a pricing tier.
--
-- So taking a backup, downloading it, and putting one back are available on
-- every plan, and stay owner-only as they always were. The rest of Owner
-- control — the print designer and the audit trail — is unchanged and stays
-- with Full.
--
-- This also makes the reset the shop asked for possible: back everything up
-- to a file on their own machine, then clear the bills and start the year
-- clean (db/52 master_reset), knowing the old figures can be read back.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The tables backup needs, off the plan's restrictive policies
-- ------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['backups', 'backup_settings'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    -- These were `restrictive ... has_feature('owner')`, which stopped a
    -- capped shop recording or scheduling a backup at all.
    execute format('drop policy if exists plan_insert on %I', t);
    execute format('drop policy if exists plan_update on %I', t);
    execute format('drop policy if exists plan_delete on %I', t);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 2. The snapshot itself
-- ------------------------------------------------------------
-- Identical to db/21's, with one line gone: the plan test. The owner check
-- stays — this is still not something a counter hand may run.
create or replace function org_snapshot(p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; spec text; parts text[]; t text; v_rows jsonb; v_tables jsonb := '{}'::jsonb; v_order text;
begin
  if is_service_call() then
    v_org := p_org;
  else
    -- No require_feature here (db/69): a shop may always take a copy of its
    -- own books, whatever it is paying for.
    if my_role() <> 'owner' then raise exception 'Only the owner can take a backup'; end if;
    v_org := my_org_id();
  end if;
  if v_org is null then raise exception 'Organisation not known'; end if;
  foreach spec in array snapshot_tables() loop
    parts := string_to_array(spec, ':');
    t := parts[1];
    v_order := case t when 'ledger_accounts' then 'order by (t.parent_id is null) desc, t.name'
                      when 'journal_entries' then 'order by (t.reverses_entry_id is null) desc, t.created_at, t.entry_no'
                      when 'receipts' then 'order by (t.reversal_of is null) desc, t.created_at'
                      when 'payments' then 'order by (t.reversal_of is null) desc, t.created_at'
                      else 'order by t.ctid' end;
    if array_length(parts, 1) = 3 then
      execute format('select coalesce(jsonb_agg(to_jsonb(t) %s), ''[]''::jsonb) from %I t where exists (select 1 from %I p where p.id = t.%I and p.org_id = $1)', v_order, t, parts[3], parts[2]) into v_rows using v_org;
    else
      execute format('select coalesce(jsonb_agg(to_jsonb(t) %s), ''[]''::jsonb) from %I t where t.org_id = $1', v_order, t) into v_rows using v_org;
    end if;
    v_tables := v_tables || jsonb_build_object(t, v_rows);
  end loop;
  return jsonb_build_object('version', 1, 'taken_at', now(), 'org_id', v_org,
                            'org', (select to_jsonb(o) - 'license_key' from orgs o where o.id = v_org),
                            'tables', v_tables);
end $$;

-- ------------------------------------------------------------
-- 3. And putting one back
-- ------------------------------------------------------------
-- restore_org_snapshot was never plan-gated: it checks the owner role and
-- nothing else, so it already works on any plan. It is named here only so the
-- next person reading this knows it was checked and not forgotten — and as a
-- warning that re-adding require_feature('owner') to either function would
-- break backup for every capped shop again.

comment on function org_snapshot(uuid) is
  'A copy of everything the org owns. Owner only, and deliberately NOT gated by the licence plan (db/69): a shop can always take its own books out.';
