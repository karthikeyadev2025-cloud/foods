-- ============================================================
-- JYOTHI FOODS ERP — ROW LEVEL SECURITY
-- Every table is scoped to the caller's org. Role checks layer
-- on top for the write-sensitive tables.
-- ============================================================

-- Caller's org (cached per statement)
create or replace function my_org_id() returns uuid
language sql stable security definer set search_path = public as $$
  select org_id from staff where auth_uid = auth.uid() and is_active limit 1;
$$;

create or replace function my_role() returns staff_role
language sql stable security definer set search_path = public as $$
  select role from staff where auth_uid = auth.uid() and is_active limit 1;
$$;

create or replace function has_role(variadic p_roles staff_role[]) returns boolean
language sql stable as $$ select my_role() = any(p_roles); $$;

-- ------------------------------------------------------------
-- Enable RLS + standard org policy on every org-scoped table
-- ------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'routes','customers','suppliers','sections','item_categories','items',
    'uoms','pack_types','receipt_modes','expense_heads','number_series',
    'role_permissions','import_jobs',
    'item_price_overrides','stock_locations','vehicles','vehicle_trips',
    'stock_ledger','purchases','invoices','sales_returns','receipts',
    'payments','recipes','production_batches','message_templates',
    'message_log','reminder_rules','catalogs','inbound_orders',
    'attendance','staff',
    -- 04_extended
    'cash_bank_accounts','account_transactions','cheques','account_transfers',
    'ledger_accounts','journal_entries','quotations','orders','delivery_challans',
    'purchase_returns','price_lists','discount_schemes','item_batches','item_barcodes',
    'print_templates','backups','transaction_message_settings'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists org_read on %I', t);
    execute format(
      'create policy org_read on %I for select using (org_id = my_org_id())', t);
    execute format('drop policy if exists org_write on %I', t);
    execute format(
      'create policy org_write on %I for all
         using (org_id = my_org_id()) with check (org_id = my_org_id())', t);
  end loop;
end $$;

-- ------------------------------------------------------------
-- Child tables inherit scope from their parent
-- ------------------------------------------------------------
alter table invoice_items        enable row level security;
alter table purchase_items       enable row level security;
alter table sales_return_items   enable row level security;
alter table receipt_lines        enable row level security;
alter table receipt_allocations  enable row level security;
alter table recipe_ingredients   enable row level security;
alter table batch_ingredients    enable row level security;

create policy child_scope on invoice_items for all
  using (exists (select 1 from invoices p where p.id = invoice_id and p.org_id = my_org_id()))
  with check (exists (select 1 from invoices p where p.id = invoice_id and p.org_id = my_org_id()));

create policy child_scope on purchase_items for all
  using (exists (select 1 from purchases p where p.id = purchase_id and p.org_id = my_org_id()))
  with check (exists (select 1 from purchases p where p.id = purchase_id and p.org_id = my_org_id()));

create policy child_scope on sales_return_items for all
  using (exists (select 1 from sales_returns p where p.id = return_id and p.org_id = my_org_id()))
  with check (exists (select 1 from sales_returns p where p.id = return_id and p.org_id = my_org_id()));

create policy child_scope on receipt_lines for all
  using (exists (select 1 from receipts p where p.id = receipt_id and p.org_id = my_org_id()))
  with check (exists (select 1 from receipts p where p.id = receipt_id and p.org_id = my_org_id()));

create policy child_scope on receipt_allocations for all
  using (exists (select 1 from receipts p where p.id = receipt_id and p.org_id = my_org_id()))
  with check (exists (select 1 from receipts p where p.id = receipt_id and p.org_id = my_org_id()));

create policy child_scope on recipe_ingredients for all
  using (exists (select 1 from recipes p where p.id = recipe_id and p.org_id = my_org_id()))
  with check (exists (select 1 from recipes p where p.id = recipe_id and p.org_id = my_org_id()));

create policy child_scope on batch_ingredients for all
  using (exists (select 1 from production_batches p where p.id = batch_id and p.org_id = my_org_id()))
  with check (exists (select 1 from production_batches p where p.id = batch_id and p.org_id = my_org_id()));

-- ------------------------------------------------------------
-- Role hardening on money + master data
-- ------------------------------------------------------------
drop policy if exists org_write on items;
create policy items_write on items for all
  using (org_id = my_org_id() and has_role('owner','admin','store_keeper'))
  with check (org_id = my_org_id() and has_role('owner','admin','store_keeper'));

drop policy if exists org_write on payments;
create policy payments_write on payments for all
  using (org_id = my_org_id() and has_role('owner','admin','accountant'))
  with check (org_id = my_org_id() and has_role('owner','admin','accountant'));

drop policy if exists org_write on staff;
create policy staff_write on staff for all
  using (org_id = my_org_id() and has_role('owner','admin'))
  with check (org_id = my_org_id() and has_role('owner','admin'));
create policy staff_self_read on staff for select using (auth_uid = auth.uid());

-- Stock ledger is append-only: writes go through the posting functions
drop policy if exists org_write on stock_ledger;
create policy stock_insert on stock_ledger for insert
  with check (org_id = my_org_id());

-- Orgs: readable only to its own staff, never writable from the client
alter table orgs enable row level security;
create policy org_self_read on orgs for select using (id = my_org_id());

-- Views inherit RLS from base tables (Postgres 15+: security_invoker)
alter view v_stock_on_hand        set (security_invoker = on);
alter view v_customer_outstanding set (security_invoker = on);
alter view v_production_sheet     set (security_invoker = on);


-- ------------------------------------------------------------
-- 04_extended child tables
-- ------------------------------------------------------------
alter table quotation_items      enable row level security;
alter table order_items          enable row level security;
alter table challan_items        enable row level security;
alter table purchase_return_items enable row level security;
alter table price_list_items     enable row level security;
alter table journal_lines        enable row level security;

create policy child_scope on quotation_items for all
  using (exists (select 1 from quotations p where p.id = quotation_id and p.org_id = my_org_id()))
  with check (exists (select 1 from quotations p where p.id = quotation_id and p.org_id = my_org_id()));

create policy child_scope on order_items for all
  using (exists (select 1 from orders p where p.id = order_id and p.org_id = my_org_id()))
  with check (exists (select 1 from orders p where p.id = order_id and p.org_id = my_org_id()));

create policy child_scope on challan_items for all
  using (exists (select 1 from delivery_challans p where p.id = challan_id and p.org_id = my_org_id()))
  with check (exists (select 1 from delivery_challans p where p.id = challan_id and p.org_id = my_org_id()));

create policy child_scope on purchase_return_items for all
  using (exists (select 1 from purchase_returns p where p.id = return_id and p.org_id = my_org_id()))
  with check (exists (select 1 from purchase_returns p where p.id = return_id and p.org_id = my_org_id()));

create policy child_scope on price_list_items for all
  using (exists (select 1 from price_lists p where p.id = price_list_id and p.org_id = my_org_id()))
  with check (exists (select 1 from price_lists p where p.id = price_list_id and p.org_id = my_org_id()));

create policy child_scope on journal_lines for all
  using (exists (select 1 from journal_entries p where p.id = entry_id and p.org_id = my_org_id()))
  with check (exists (select 1 from journal_entries p where p.id = entry_id and p.org_id = my_org_id()));

-- Backup settings is one row per org
alter table backup_settings enable row level security;
create policy org_scope on backup_settings for all
  using (org_id = my_org_id()) with check (org_id = my_org_id());

-- Journals are append-only; corrections are reversing entries
drop policy if exists org_write on journal_entries;
create policy journal_insert on journal_entries for insert with check (org_id = my_org_id());
