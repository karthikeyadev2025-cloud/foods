-- ============================================================
-- JYOTHI FOODS ERP — 04: FULL BUSINESS COVERAGE
-- Orders & challans · quotations · cash and bank · double-entry
-- ledger · price lists · batches & expiry · barcodes · print
-- templates · backups.
-- SINGLE TRADE NAME: JYOTHI FOODS. There is no firm dimension —
-- R.K.BAKERY and the OTHERS groups are production SECTIONS, not
-- separate firms. Do not reintroduce one.
-- Everything here is client-managed from Setup, same as 01.
-- ============================================================

-- ------------------------------------------------------------
-- 1. CASH & BANK
-- ------------------------------------------------------------
create type account_kind as enum ('cash','bank','wallet');

create table cash_bank_accounts (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  name            text not null,              -- 'Cash in hand', 'SBI Current'
  kind            account_kind not null default 'bank',
  bank_name       text,
  account_last4   text,                       -- last four digits only, never the full number
  ifsc            text,
  opening_balance numeric(14,2) not null default 0,
  as_on           date default current_date,
  is_active       boolean not null default true,
  unique (org_id, name)
);

-- Every rupee in or out of a cash/bank account
create table account_transactions (
  id           bigserial primary key,
  org_id       uuid not null references orgs(id) on delete cascade,
  account_id   uuid not null references cash_bank_accounts(id),
  txn_date     date not null default current_date,
  amount       numeric(14,2) not null,        -- +in / -out
  narration    text,
  ref_table    text,
  ref_id       uuid,
  created_by   uuid references staff(id),
  created_at   timestamptz not null default now()
);
create index on account_transactions(org_id, account_id, txn_date);

alter table receipts add column account_id uuid references cash_bank_accounts(id);
alter table payments add column account_id uuid references cash_bank_accounts(id);

-- Cheques in hand / issued, with clearing status
create type cheque_direction as enum ('received','issued');
create type cheque_state     as enum ('in_hand','deposited','cleared','bounced','cancelled');

create table cheques (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  direction    cheque_direction not null,
  party_kind   text,                          -- 'customer' | 'supplier'
  customer_id  uuid references customers(id),
  supplier_id  uuid references suppliers(id),
  cheque_no    text not null,
  cheque_date  date,
  bank_name    text,
  amount       numeric(14,2) not null,
  state        cheque_state not null default 'in_hand',
  account_id   uuid references cash_bank_accounts(id),
  cleared_on   date,
  ref_table    text,
  ref_id       uuid,
  notes        text
);
create index on cheques(org_id, state, cheque_date);

-- Account transfers (cash → bank, bank → bank)
create table account_transfers (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  from_account uuid not null references cash_bank_accounts(id),
  to_account   uuid not null references cash_bank_accounts(id),
  txn_date     date not null default current_date,
  amount       numeric(14,2) not null,
  narration    text,
  created_by   uuid references staff(id)
);

-- ------------------------------------------------------------
-- 3. DOUBLE-ENTRY LEDGER
--    Documents post journal entries. This is what makes a real
--    trial balance, P&L and balance sheet possible — as opposed to
--    a "profit" number assembled from four unrelated SUM()s.
-- ------------------------------------------------------------
create type account_type as enum ('asset','liability','income','expense','equity');

create table ledger_accounts (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  code         text,
  name         text not null,
  type         account_type not null,
  parent_id    uuid references ledger_accounts(id),
  -- links a control account to its subsidiary master
  customer_id  uuid references customers(id),
  supplier_id  uuid references suppliers(id),
  account_id   uuid references cash_bank_accounts(id),
  is_system    boolean not null default false,   -- system accounts can't be deleted
  is_active    boolean not null default true,
  unique (org_id, name)
);

create table journal_entries (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  entry_no    text,
  entry_date  date not null default current_date,
  narration   text,
  ref_table   text,
  ref_id      uuid,
  is_manual   boolean not null default false,
  created_by  uuid references staff(id),
  created_at  timestamptz not null default now()
);
create index on journal_entries(org_id, entry_date);
create index on journal_entries(ref_table, ref_id);

create table journal_lines (
  id         bigserial primary key,
  entry_id   uuid not null references journal_entries(id) on delete cascade,
  account_id uuid not null references ledger_accounts(id),
  debit      numeric(14,2) not null default 0,
  credit     numeric(14,2) not null default 0,
  narration  text,
  check (debit >= 0 and credit >= 0),
  check (not (debit > 0 and credit > 0))
);
create index on journal_lines(account_id);

-- ------------------------------------------------------------
-- 4. ORDERS, QUOTATIONS, CHALLANS
--    The client's own paper form is headed QUOTATION, so this is
--    the document they actually start from.
-- ------------------------------------------------------------
create type doc_state as enum ('open','partial','completed','cancelled','converted');

create table quotations (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  quote_no     text,
  customer_id  uuid not null references customers(id),
  quote_date   date not null default current_date,
  valid_till   date,
  transport_name text,
  lr_no        text,
  lr_date      date,
  freight      numeric(12,2) default 0,
  subtotal     numeric(14,2) not null default 0,
  discount     numeric(14,2) not null default 0,
  round_off    numeric(8,2)  not null default 0,
  total        numeric(14,2) not null default 0,
  state        doc_state not null default 'open',
  invoice_id   uuid references invoices(id),
  notes        text,
  created_by   uuid references staff(id),
  created_at   timestamptz not null default now()
);

create table quotation_items (
  id            uuid primary key default gen_random_uuid(),
  quotation_id  uuid not null references quotations(id) on delete cascade,
  item_id       uuid not null references items(id),
  units_per_box numeric(12,3) not null default 1,
  boxes         numeric(16,3) not null default 0,
  qty           numeric(16,3) not null default 0,
  uom_id        uuid references uoms(id),
  qty_base      numeric(16,3) not null default 0,
  rate          numeric(12,2) not null default 0,
  amount        numeric(14,2) not null default 0
);

create type order_kind as enum ('sale','purchase');

create table orders (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  kind         order_kind not null,
  order_no     text,
  customer_id  uuid references customers(id),
  supplier_id  uuid references suppliers(id),
  order_date   date not null default current_date,
  due_date     date,
  total        numeric(14,2) not null default 0,
  advance      numeric(14,2) not null default 0,
  state        doc_state not null default 'open',
  source_inbound_id uuid references inbound_orders(id),
  notes        text,
  created_by   uuid references staff(id)
);

create table order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references orders(id) on delete cascade,
  item_id       uuid not null references items(id),
  units_per_box numeric(12,3) not null default 1,
  boxes         numeric(16,3) not null default 0,
  qty           numeric(16,3) not null default 0,
  uom_id        uuid references uoms(id),
  qty_base      numeric(16,3) not null default 0,
  delivered_base numeric(16,3) not null default 0,
  rate          numeric(12,2) not null default 0,
  amount        numeric(14,2) not null default 0
);

-- Goods moved before/without a bill
create table delivery_challans (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  challan_no   text,
  customer_id  uuid not null references customers(id),
  challan_date date not null default current_date,
  location_id  uuid references stock_locations(id),
  vehicle_id   uuid references vehicles(id),
  trip_id      uuid references vehicle_trips(id),
  state        doc_state not null default 'open',
  invoice_id   uuid references invoices(id),
  notes        text,
  created_by   uuid references staff(id)
);

create table challan_items (
  id            uuid primary key default gen_random_uuid(),
  challan_id    uuid not null references delivery_challans(id) on delete cascade,
  item_id       uuid not null references items(id),
  units_per_box numeric(12,3) not null default 1,
  boxes         numeric(16,3) not null default 0,
  qty           numeric(16,3) not null default 0,
  uom_id        uuid references uoms(id),
  qty_base      numeric(16,3) not null default 0
);

-- Debit note to a supplier (mirror of sales_returns)
create table purchase_returns (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  return_no    text,
  supplier_id  uuid not null references suppliers(id),
  purchase_id  uuid references purchases(id),
  return_date  date not null default current_date,
  location_id  uuid references stock_locations(id),
  total        numeric(14,2) not null default 0,
  notes        text,
  created_by   uuid references staff(id)
);

create table purchase_return_items (
  id         uuid primary key default gen_random_uuid(),
  return_id  uuid not null references purchase_returns(id) on delete cascade,
  item_id    uuid not null references items(id),
  qty        numeric(16,3) not null default 0,
  uom_id     uuid references uoms(id),
  qty_base   numeric(16,3) not null default 0,
  rate       numeric(12,2) not null default 0,
  amount     numeric(14,2) not null default 0
);

-- ------------------------------------------------------------
-- 5. PRICE LISTS  (replaces ad-hoc overrides with named lists)
-- ------------------------------------------------------------
create table price_lists (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  name       text not null,                 -- 'Wholesale', 'Retail', 'Guntur route'
  valid_from date default current_date,
  valid_to   date,
  is_default boolean not null default false,
  is_active  boolean not null default true,
  unique (org_id, name)
);

create table price_list_items (
  id            uuid primary key default gen_random_uuid(),
  price_list_id uuid not null references price_lists(id) on delete cascade,
  item_id       uuid not null references items(id) on delete cascade,
  unit_rate     numeric(12,2) not null,
  unique (price_list_id, item_id)
);

alter table customers add column price_list_id uuid references price_lists(id);

-- Discount schemes (e.g. 1 box free on 10)
create table discount_schemes (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  name          text not null,
  item_id       uuid references items(id),
  section_id    uuid references sections(id),
  min_boxes     numeric(12,3) default 0,
  discount_pct  numeric(5,2)  default 0,
  free_boxes    numeric(12,3) default 0,
  valid_from    date default current_date,
  valid_to      date,
  is_active     boolean not null default true
);

-- ------------------------------------------------------------
-- 6. BATCHES & EXPIRY  (food manufacturer — shelf life matters)
-- ------------------------------------------------------------
create table item_batches (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  item_id        uuid not null references items(id) on delete cascade,
  batch_no       text not null,
  mfg_date       date,
  expiry_date    date,
  production_batch_id uuid references production_batches(id),
  unique (org_id, item_id, batch_no)
);
create index on item_batches(org_id, expiry_date);

alter table stock_ledger add column batch_id uuid references item_batches(id);

-- ------------------------------------------------------------
-- 7. BARCODES
-- ------------------------------------------------------------
create table item_barcodes (
  id        uuid primary key default gen_random_uuid(),
  org_id    uuid not null references orgs(id) on delete cascade,
  item_id   uuid not null references items(id) on delete cascade,
  barcode   text not null,
  uom_id    uuid references uoms(id),        -- barcode may identify a box or a jar
  unique (org_id, barcode)
);

-- ------------------------------------------------------------
-- 8. PRINT TEMPLATES  (client edits layout without a deploy)
-- ------------------------------------------------------------
create table print_templates (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  doc_type    text not null,                -- 'invoice','quotation','challan','receipt','loading_sheet'
  name        text not null,
  paper       text not null default 'A4',   -- A4 | A5 | thermal_80 | thermal_58
  show_fields jsonb not null default '{}',  -- which columns/blocks are visible
  header_html text,
  footer_html text,
  terms       text[],                       -- numbered terms printed at the bottom
  is_default  boolean not null default false,
  unique (org_id, doc_type, name)
);

-- ------------------------------------------------------------
-- 9. BACKUP & RESTORE
-- ------------------------------------------------------------
create type backup_status as enum ('running','ready','failed','restored');

create table backups (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  file_path   text,                          -- Supabase Storage
  size_bytes  bigint,
  status      backup_status not null default 'running',
  is_auto     boolean not null default false,
  created_by  uuid references staff(id),
  created_at  timestamptz not null default now()
);

create table backup_settings (
  org_id       uuid primary key references orgs(id) on delete cascade,
  auto_enabled boolean not null default true,
  frequency    text not null default 'daily',   -- daily | weekly
  keep_copies  integer not null default 30,
  run_at       time not null default '23:30'
);

-- ------------------------------------------------------------
-- 10. TRANSACTION MESSAGE SETTINGS
--     Which documents auto-send a WhatsApp, and using which template.
-- ------------------------------------------------------------
create table transaction_message_settings (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  doc_type     text not null,               -- 'invoice','receipt','order','challan'
  is_enabled   boolean not null default false,
  template_id  uuid references message_templates(id),
  send_pdf     boolean not null default true,
  unique (org_id, doc_type)
);

-- ------------------------------------------------------------
-- 11. REPORTING VIEWS
-- ------------------------------------------------------------

-- Day book: every money movement of the day, one list
create or replace view v_day_book as
select org_id, 'Invoice'  as doc, invoice_no  as doc_no, invoice_date  as doc_date,
       customer_id as party_id, total as amount, 'in'  as direction from invoices where status <> 'cancelled'
union all
select org_id, 'Receipt',  receipt_no,  receipt_date,  customer_id, total_amount, 'in'  from receipts
union all
select org_id, 'Purchase', bill_no,     bill_date,     null,        total,        'out' from purchases
union all
select org_id, 'Payment',  payment_no,  payment_date,  null,        amount,       'out' from payments
union all
select org_id, 'Return',   return_no,   return_date,   customer_id, total,        'out' from sales_returns;

-- Trial balance straight off the journal
create or replace view v_trial_balance as
select la.org_id, la.id as account_id, la.code, la.name, la.type,
       coalesce(sum(jl.debit),0)  as total_debit,
       coalesce(sum(jl.credit),0) as total_credit,
       coalesce(sum(jl.debit),0) - coalesce(sum(jl.credit),0) as balance
from ledger_accounts la
left join journal_lines   jl on jl.account_id = la.id
left join journal_entries je on je.id = jl.entry_id
group by la.org_id, la.id, la.code, la.name, la.type;

-- Cash / bank balances
create or replace view v_account_balances as
select a.org_id, a.id as account_id, a.name, a.kind,
       a.opening_balance + coalesce(sum(t.amount),0) as balance
from cash_bank_accounts a
left join account_transactions t on t.account_id = a.id
group by a.org_id, a.id, a.name, a.kind, a.opening_balance;

-- Item-wise profitability (sale value vs production/purchase cost)
create or replace view v_item_profit as
select i.org_id, i.id as item_id, i.item_code, i.name,
       coalesce(sum(ii.amount),0)                       as sale_value,
       coalesce(sum(ii.qty_base * i.purchase_rate),0)   as cost_value,
       coalesce(sum(ii.amount),0) - coalesce(sum(ii.qty_base * i.purchase_rate),0)
         as gross_profit
from items i
left join invoice_items ii on ii.item_id = i.id
left join invoices inv on inv.id = ii.invoice_id and inv.status <> 'cancelled'
group by i.org_id, i.id, i.item_code, i.name;
