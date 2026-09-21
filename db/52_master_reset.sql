-- ============================================================
-- JYOTHI FOODS ERP — 52: MASTER RESET
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "i want to reset all data once master reset and start doing all fresh from
-- begining."
--
-- Fair. The figures that went in while the purchase screen was counting jars as
-- boxes are not worth unpicking one at a time, and a shop that does not trust
-- its own stock report will not use it.
--
-- THIS CANNOT BE UNDONE. So it is built the way a thing that cannot be undone
-- should be:
--
--   * Owner only.
--   * The org's own NAME has to be typed in. Not "yes", not a tick box — the
--     name, exactly, because somebody who cannot be bothered to type it is
--     somebody who has not read what it does.
--   * It says what it deleted, table by table, rather than reporting "done".
--   * Three scopes, so nobody has to throw away the product list to clear a
--     week of wrong bills.
--
-- WHAT IS NEVER DELETED, at any scope: the organisation itself, the staff and
-- their logins, the role permissions, the licence and its devices, the backups,
-- and the settings that hold keys you cannot get back — WhatsApp, Punchly,
-- print templates. Wiping those would lock the shop out of its own system to no
-- purpose.
--
-- THE SCOPES
--   transactions  Every bill, purchase, receipt, payment, return, quotation,
--                 order, challan, batch, trip, transfer, count, cheque, journal
--                 and stock movement. Products, customers, suppliers, prices,
--                 recipes and all of Setup stay exactly as they are.
--
--   masters       The above, plus products, customers, suppliers, vehicles,
--                 routes, price lists, discount schemes, barcodes and recipes.
--                 Setup — units, pack types, sections, godowns, receipt modes,
--                 numbering — stays.
--
--   everything    The above, plus Setup itself. Back to the morning the
--                 organisation was created, with the staff still able to log in.
--
-- In every scope the document numbers go back to 1, so the first bill after a
-- reset is bill one and not bill twelve.
--
-- The list of tables and the ORDER they come out in is taken from
-- snapshot_tables() — the same list the backup uses — rather than written out
-- again here. A list written twice is a list that drifts, and the day it drifts
-- is the day a reset leaves half a ledger behind.
-- ============================================================

/**
 * What a reset of this scope leaves alone. Everything else in snapshot_tables()
 * is cleared.
 *
 * Written as what to KEEP rather than what to delete, deliberately: a table
 * added to the system later is then cleared by default. Forgetting to delete
 * leaves rows behind that reference nothing; forgetting to keep is visible the
 * moment somebody looks.
 */
create or replace function reset_keeps(p_scope text) returns text[]
language sql immutable as $$
  select case p_scope
    when 'transactions' then array[
      'uoms','pack_types','item_categories','sections','items','item_price_overrides',
      'price_lists','price_list_items','discount_schemes','item_barcodes','routes',
      'customers','suppliers','stock_locations','vehicles','expense_heads',
      'cash_bank_accounts','receipt_modes','number_series','role_permissions',
      'ledger_accounts','recipes','recipe_ingredients',
      'message_templates','reminder_rules','catalogs','new_stock_rules',
      'transaction_message_settings','messaging_settings','print_templates','staff']
    when 'masters' then array[
      'uoms','pack_types','sections','stock_locations','expense_heads',
      'cash_bank_accounts','receipt_modes','number_series','role_permissions',
      'ledger_accounts',
      'message_templates','reminder_rules','catalogs','new_stock_rules',
      'transaction_message_settings','messaging_settings','print_templates','staff']
    when 'everything' then array[
      -- The system ledger and cash/bank accounts are not shop data: they are
      -- created on demand and a trigger refuses to delete them. They are
      -- emptied by the journal and bank rows going, not by being removed.
      'ledger_accounts','cash_bank_accounts',
      'number_series','role_permissions',
      'transaction_message_settings','messaging_settings','print_templates','staff']
    else null end;
$$;

/**
 * Wipe this organisation's data and start again.
 *
 * p_confirm must be the organisation's name, exactly as it is stored.
 * p_scope is 'transactions', 'masters' or 'everything'.
 *
 * Returns one row per table with what it removed, most first — so the person
 * who ran it can see it did what they thought, and keep the list.
 */
create or replace function master_reset(p_confirm text, p_scope text default 'transactions')
returns table (table_name text, rows_deleted bigint)
language plpgsql security definer set search_path = public as $$
declare
  v_org   uuid := my_org_id();
  v_name  text;
  v_keeps text[];
  spec    text;
  t       text;
  fk      text;
  parent  text;
  n       bigint;
  specs   text[];
begin
  if v_org is null then raise exception 'Not signed in to an organisation'; end if;
  if my_role() <> 'owner' then
    raise exception 'Only an owner can reset the data' using errcode = '42501';
  end if;

  v_keeps := reset_keeps(p_scope);
  if v_keeps is null then
    raise exception 'Scope must be transactions, masters or everything — not "%"', p_scope;
  end if;

  select name into v_name from orgs where id = v_org;
  -- The name, typed. A tick box is something a hand does; a name is something a
  -- person has to have read the screen to produce.
  if btrim(coalesce(p_confirm, '')) <> btrim(v_name) then
    raise exception 'To reset, type the business name exactly: %. This cannot be undone — take a backup from Setup → Backup first.', v_name
      using errcode = '42501';
  end if;

  -- A confirmed bill's lines cannot be deleted while it is confirmed — a guard
  -- that is right for editing and wrong here, because this is not an edit. The
  -- bills are set back to draft first rather than the guard being switched off:
  -- it is one statement, it needs no privileges, and it cannot leave a
  -- protection disabled if something later in this function fails. The rows are
  -- deleted moments later anyway.
  update invoices set status = 'draft' where org_id = v_org and status <> 'draft';

  -- Reverse of the backup's order: children before the parents they hang off.
  select array_agg(s order by i desc) into specs
    from unnest(snapshot_tables()) with ordinality as x(s, i);

  foreach spec in array specs || array['import_jobs'] loop
    t      := split_part(spec, ':', 1);
    fk     := nullif(split_part(spec, ':', 2), '');
    parent := nullif(split_part(spec, ':', 3), '');
    continue when t = any (v_keeps);

    if fk is null then
      -- Has its own org_id.
      execute format('delete from public.%I where org_id = $1', t) using v_org;
    else
      -- A line table: reached through the document it belongs to.
      execute format('delete from public.%I where %I in (select id from public.%I where org_id = $1)',
                     t, fk, parent) using v_org;
    end if;
    get diagnostics n = row_count;

    if n > 0 then
      table_name   := t;
      rows_deleted := n;
      return next;
    end if;
  end loop;

  -- Numbering starts again, whatever the scope. A shop starting fresh expects
  -- bill 1, and leaving the counter at 12 is the sort of detail that makes
  -- somebody doubt the whole reset worked.
  update number_series set next_number = 1, last_reset = null where org_id = v_org;

  -- The opening figures are about to be typed in again, so the window that lets
  -- a wrong stock row be removed is re-opened for thirty days (db/49).
  update orgs set stock_delete_until = current_date + 30 where id = v_org;
end $$;

revoke execute on function master_reset(text, text) from public, anon;
grant  execute on function master_reset(text, text) to authenticated;
grant  execute on function reset_keeps(text) to authenticated;
