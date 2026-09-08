-- ============================================================
-- JYOTHI FOODS ERP — 17: OWNER CONTROL (T10)
-- Business profile extras, print templates, audit trail, and
-- org snapshot / restore for backups.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Business profile: logo, signature, contact and bank lines
--    for the printed documents. Single trade name, no multi-firm.
-- ------------------------------------------------------------
alter table orgs
  add column if not exists logo_url text,
  add column if not exists signature_url text,
  add column if not exists email text,
  add column if not exists tagline text,
  add column if not exists bank_details text;

create or replace view v_me as
select s.id as staff_id, s.auth_uid, s.full_name, s.phone, s.role, s.is_mestry, s.is_active,
       o.id as org_id, o.name as org_name, o.address, o.phone as org_phone, o.fssai_no,
       o.breakage_recovery_pct, o.interest_pct_pa, o.credit_days, o.jurisdiction,
       o.license_valid_till,
       o.logo_url, o.signature_url, o.email as org_email, o.tagline, o.bank_details
from staff s join orgs o on o.id = s.org_id
where s.auth_uid = auth.uid();
alter view v_me set (security_invoker = on);

-- ------------------------------------------------------------
-- 2. Print templates: one per document type and paper size;
--    the owner toggles blocks and edits the numbered terms.
-- ------------------------------------------------------------
alter table print_templates add column if not exists updated_at timestamptz not null default now();
create unique index if not exists print_templates_default_idx on print_templates(org_id, doc_type) where is_default;

/** Save (or create) the template for a document type. Only one default per type. */
create or replace function save_print_template(p jsonb) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid; v_doc text := p->>'doc_type';
begin
  if not can_edit('setup') then raise exception 'Only Setup editors can change print templates'; end if;
  if v_doc is null or v_doc = '' then raise exception 'doc_type is required'; end if;
  insert into print_templates (org_id, doc_type, name, paper, show_fields, header_html, footer_html, terms, is_default)
  values (v_org, v_doc, coalesce(nullif(p->>'name', ''), 'Default'), coalesce(nullif(p->>'paper', ''), 'A4'),
          coalesce(p->'show_fields', '{}'::jsonb), nullif(p->>'header_html', ''), nullif(p->>'footer_html', ''),
          case when jsonb_typeof(p->'terms') = 'array' then array(select jsonb_array_elements_text(p->'terms')) end, true)
  on conflict (org_id, doc_type, name) do update set
    paper = excluded.paper, show_fields = excluded.show_fields, header_html = excluded.header_html, footer_html = excluded.footer_html,
    terms = excluded.terms, is_default = true, updated_at = now()
  returning id into v_id;
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 3. Audit trail: who changed what. One trigger, attached to the
--    masters, settings and document headers. Updates keep only
--    the fields that changed.
-- ------------------------------------------------------------
create or replace function audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_before jsonb; v_after jsonb; v_row jsonb; v_org uuid; k text; d_before jsonb := '{}'::jsonb; d_after jsonb := '{}'::jsonb;
begin
  if tg_op in ('UPDATE', 'DELETE') then v_before := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_after := to_jsonb(new); end if;
  v_row := coalesce(v_after, v_before);
  v_org := case when tg_table_name = 'orgs' then (v_row->>'id')::uuid else (v_row->>'org_id')::uuid end;
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(v_after) loop
      if k in ('updated_at') then continue; end if;
      if v_before->k is distinct from v_after->k then
        d_before := d_before || jsonb_build_object(k, v_before->k);
        d_after := d_after || jsonb_build_object(k, v_after->k);
      end if;
    end loop;
    if d_after = '{}'::jsonb then return null; end if;
    v_before := d_before; v_after := d_after;
  end if;
  -- never keep secrets in the trail
  v_before := v_before - 'api_key' - 'webhook_secret' - 'license_key';
  v_after := v_after - 'api_key' - 'webhook_secret' - 'license_key';
  insert into audit_log (org_id, actor, action, table_name, row_id, before, after)
  values (v_org, my_staff_id(), tg_op, tg_table_name, v_row->>'id', v_before, v_after);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'orgs', 'staff', 'role_permissions', 'number_series', 'uoms', 'pack_types', 'receipt_modes', 'expense_heads', 'sections', 'stock_locations', 'routes',
    'items', 'item_price_overrides', 'customers', 'suppliers', 'vehicles', 'price_lists', 'discount_schemes',
    'invoices', 'quotations', 'orders', 'delivery_challans', 'purchases', 'purchase_returns', 'sales_returns', 'receipts', 'payments', 'cheques',
    'cash_bank_accounts', 'ledger_accounts', 'account_transfers', 'stock_transfers', 'stock_counts', 'production_batches', 'recipes',
    'message_templates', 'reminder_rules', 'transaction_message_settings', 'print_templates', 'backup_settings'
  ] loop
    execute format('drop trigger if exists t_audit on %I', t);
    execute format('create trigger t_audit after insert or update or delete on %I for each row execute function audit_row()', t);
  end loop;
end $$;

create or replace view v_audit_log as
select a.*, st.full_name as actor_name, st.role as actor_role
  from audit_log a left join staff st on st.id = a.actor;
alter view v_audit_log set (security_invoker = on);

create or replace function audit_search(p_from timestamptz default null, p_to timestamptz default null, p_table text default null, p_actor uuid default null, p_action text default null, p_search text default null, p_limit int default 200)
returns setof v_audit_log language sql stable as $$
  select * from v_audit_log a
   where a.org_id = my_org_id()
     and (p_from is null or a.created_at >= p_from) and (p_to is null or a.created_at <= p_to)
     and (p_table is null or a.table_name = p_table) and (p_actor is null or a.actor = p_actor)
     and (p_action is null or a.action = p_action)
     and (p_search is null or p_search = '' or a.row_id ilike '%' || p_search || '%' or coalesce(a.after::text, '') ilike '%' || p_search || '%' or coalesce(a.before::text, '') ilike '%' || p_search || '%')
   order by a.created_at desc, a.id desc
   limit least(coalesce(p_limit, 200), 1000);
$$;

-- ------------------------------------------------------------
-- 4. Backup: the org's data as one JSON snapshot, and restore.
--    The edge function stores the file; these two do the work.
-- ------------------------------------------------------------
create or replace function snapshot_tables() returns text[]
language sql immutable as $$
  select array[
    'uoms', 'pack_types', 'item_categories', 'sections', 'items', 'item_price_overrides', 'price_lists', 'price_list_items:price_list_id:price_lists',
    'discount_schemes', 'item_barcodes', 'routes', 'customers', 'suppliers', 'stock_locations', 'vehicles', 'expense_heads', 'cash_bank_accounts', 'receipt_modes',
    'number_series', 'role_permissions', 'ledger_accounts', 'recipes', 'recipe_ingredients:recipe_id:recipes', 'production_batches', 'batch_ingredients:batch_id:production_batches',
    'item_batches', 'vehicle_trips', 'invoices', 'invoice_items:invoice_id:invoices', 'inbound_orders', 'quotations', 'quotation_items:quotation_id:quotations',
    'orders', 'order_items:order_id:orders', 'order_fulfilments', 'delivery_challans', 'challan_items:challan_id:delivery_challans',
    'purchases', 'purchase_items:purchase_id:purchases', 'purchase_returns', 'purchase_return_items:return_id:purchase_returns',
    'sales_returns', 'sales_return_items:return_id:sales_returns', 'receipts', 'receipt_lines:receipt_id:receipts', 'receipt_allocations:receipt_id:receipts',
    'payments', 'cheques', 'account_transfers', 'stock_transfers', 'stock_transfer_items:transfer_id:stock_transfers', 'stock_counts', 'stock_count_items:count_id:stock_counts',
    'stock_ledger', 'journal_entries', 'journal_lines:entry_id:journal_entries', 'account_transactions',
    'message_templates', 'reminder_rules', 'catalogs', 'broadcasts', 'new_stock_rules', 'message_log', 'transaction_message_settings', 'messaging_settings',
    'print_templates', 'attendance', 'staff'
  ];
$$;

/** Everything the org owns, one JSON object. Owner or the service role. */
create or replace function org_snapshot(p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; spec text; parts text[]; t text; v_rows jsonb; v_tables jsonb := '{}'::jsonb; v_order text;
begin
  if is_service_call() then
    v_org := p_org;
  else
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

/**
 * Put the org back exactly as the snapshot had it. Deletes what the org owns now (documents
 * first, masters last), then re-inserts every table in dependency order with triggers off so
 * history is copied, not re-posted. Staff logins and the audit trail are kept.
 */
create or replace function restore_org_snapshot(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; spec text; parts text[]; t text; specs text[]; i int; n int; v_counts jsonb := '{}'::jsonb; v_rows jsonb; v_cols text;
        skip text[] := array['staff', 'messaging_settings'];
begin
  if not is_service_call() and my_role() <> 'owner' then raise exception 'Only the owner can restore'; end if;
  v_org := (p->>'org_id')::uuid;
  if v_org is null or jsonb_typeof(p->'tables') <> 'object' then raise exception 'Not a backup file'; end if;
  if not is_service_call() and v_org is distinct from my_org_id() then raise exception 'This backup belongs to another organisation'; end if;
  specs := snapshot_tables();

  -- triggers off on every table so restored rows are copied, not re-posted
  foreach spec in array specs loop
    t := (string_to_array(spec, ':'))[1];
    if t = any(skip) then continue; end if;
    execute format('alter table %I disable trigger user', t);
  end loop;

  -- delete: dependents first
  for i in reverse array_length(specs, 1)..1 loop
    parts := string_to_array(specs[i], ':');
    t := parts[1];
    if t = any(skip) then continue; end if;
    if array_length(parts, 1) = 3 then
      execute format('delete from %I where %I in (select id from %I where org_id = $1)', t, parts[2], parts[3]) using v_org;
    else
      execute format('delete from %I where org_id = $1', t) using v_org;
    end if;
  end loop;

  -- insert: parents first
  foreach spec in array specs loop
    parts := string_to_array(spec, ':');
    t := parts[1];
    if t = any(skip) then continue; end if;
    v_rows := p->'tables'->t;
    if v_rows is null or jsonb_typeof(v_rows) <> 'array' then continue; end if;
    -- generated columns are recomputed, everything else is copied as it was
    select string_agg(format('%I', c.column_name), ', ' order by c.ordinal_position) into v_cols
      from information_schema.columns c
     where c.table_schema = 'public' and c.table_name = t and c.is_generated = 'NEVER' and coalesce(c.identity_generation, '') <> 'ALWAYS';
    execute format('insert into %I (%s) select %s from jsonb_populate_recordset(null::%I, $1)', t, v_cols, v_cols, t) using v_rows;
    get diagnostics n = row_count;
    v_counts := v_counts || jsonb_build_object(t, n);
  end loop;

  foreach spec in array specs loop
    t := (string_to_array(spec, ':'))[1];
    if t = any(skip) then continue; end if;
    execute format('alter table %I enable trigger user', t);
  end loop;

  -- the org row itself (profile and terms), never the licence
  if jsonb_typeof(p->'org') = 'object' then
    update orgs o set name = coalesce(p->'org'->>'name', o.name), address = p->'org'->>'address', phone = p->'org'->>'phone', fssai_no = p->'org'->>'fssai_no',
           breakage_recovery_pct = coalesce((p->'org'->>'breakage_recovery_pct')::numeric, o.breakage_recovery_pct),
           interest_pct_pa = coalesce((p->'org'->>'interest_pct_pa')::numeric, o.interest_pct_pa),
           credit_days = coalesce((p->'org'->>'credit_days')::int, o.credit_days), jurisdiction = p->'org'->>'jurisdiction',
           logo_url = p->'org'->>'logo_url', signature_url = p->'org'->>'signature_url', email = p->'org'->>'email', tagline = p->'org'->>'tagline', bank_details = p->'org'->>'bank_details'
     where o.id = v_org;
  end if;

  -- serial ids came back with the rows; move the sequences past them
  perform setval('stock_ledger_id_seq', greatest((select coalesce(max(id), 0) from stock_ledger), 1));
  perform setval('journal_lines_id_seq', greatest((select coalesce(max(id), 0) from journal_lines), 1));
  perform setval('account_transactions_id_seq', greatest((select coalesce(max(id), 0) from account_transactions), 1));

  insert into audit_log (org_id, actor, action, table_name, row_id, after)
  values (v_org, my_staff_id(), 'RESTORE', 'orgs', v_org::text, jsonb_build_object('taken_at', p->>'taken_at', 'tables', v_counts));
  return jsonb_build_object('org_id', v_org, 'restored', v_counts, 'taken_at', p->>'taken_at');
end $$;

create or replace view v_backups as
select b.*, st.full_name as created_by_name
  from backups b left join staff st on st.id = b.created_by;
alter view v_backups set (security_invoker = on);

/** Settings row on demand so the screen always has one. */
create or replace function get_backup_settings() returns backup_settings
language plpgsql security definer set search_path = public as $$
declare s backup_settings;
begin
  if not can_view('setup') then raise exception 'Setup is not available to your role'; end if;
  insert into backup_settings (org_id) values (my_org_id()) on conflict (org_id) do nothing;
  select * into s from backup_settings where org_id = my_org_id();
  return s;
end $$;

/** Which orgs are due an automatic backup this hour (the scheduler asks with the service role). */
create or replace function backups_due(p_now timestamptz default now())
returns table (org_id uuid, keep_copies integer)
language sql stable security definer set search_path = public as $$
  select s.org_id, s.keep_copies
    from backup_settings s
   where s.auto_enabled
     and extract(hour from s.run_at) = extract(hour from p_now at time zone 'Asia/Kolkata')
     and not exists (select 1 from backups b where b.org_id = s.org_id and b.is_auto and b.status = 'ready'
                       and b.created_at > p_now - case s.frequency when 'weekly' then interval '6 days 23 hours' else interval '23 hours' end);
$$;

-- ------------------------------------------------------------
-- 5. Transaction messages: attach the document. The message
--    carries a link to the document's print page (orgs.app_url is
--    where this app is hosted); Hey Nikki fetches it as the media.
-- ------------------------------------------------------------
alter table orgs add column if not exists app_url text;
alter table transaction_message_settings add column if not exists send_pdf boolean not null default false;

create or replace function queue_document_message(p_doc_type text, p_customer uuid, p_vars jsonb, p_ref_table text, p_ref_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare s transaction_message_settings%rowtype; v_org uuid; v_purpose msg_purpose; v_base text; v_media text;
begin
  select org_id into v_org from customers where id = p_customer;
  select * into s from transaction_message_settings where org_id = v_org and doc_type = p_doc_type and is_enabled;
  if not found then return null; end if;
  if not exists (select 1 from messaging_settings where org_id = v_org and is_enabled) then return null; end if;
  v_purpose := case p_doc_type when 'invoice' then 'invoice' when 'delivery' then 'delivery'
                               when 'order_ack' then 'order_ack' else 'custom' end;
  if s.send_pdf then
    select rtrim(app_url, '/') into v_base from orgs where id = v_org;
    if v_base is not null and p_ref_table = 'invoices' then v_media := v_base || '/invoices/' || p_ref_id || '/print?pdf=1'; end if;
    if v_base is not null and p_ref_table = 'receipts' then v_media := v_base || '/receipts/' || p_ref_id; end if;
  end if;
  return queue_message(jsonb_build_object('customer_id', p_customer, 'purpose', v_purpose, 'template_id', s.template_id,
                                          'vars', p_vars, 'ref_table', p_ref_table, 'ref_id', p_ref_id, 'media_url', v_media));
exception when others then
  -- A missing template must never block the document itself.
  raise warning 'Message for % % not queued: %', p_doc_type, p_ref_id, sqlerrm;
  return null;
end $$;
