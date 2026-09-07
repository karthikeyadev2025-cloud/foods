-- ============================================================
-- JYOTHI FOODS ERP — CORE SCHEMA (Supabase / Postgres)
-- Modules: Accounting, Stock, Integrations, Reminders,
--          Production, Vehicle
-- ============================================================

create extension if not exists "pgcrypto";
create extension if not exists "pg_trgm";

-- ------------------------------------------------------------
-- 0. ORG / STAFF  (multi-tenant base, same pattern as MyStore OS)
-- ------------------------------------------------------------
create table orgs (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  address       text,
  phone         text,
  fssai_no      text,
  license_key   text unique,          -- for the .exe activation
  license_valid_till date,
  -- Trade terms printed on the quotation
  breakage_recovery_pct numeric(5,2) not null default 50,   -- "damage or breakage only 50% recovery"
  interest_pct_pa       numeric(5,2) not null default 24,   -- "interest at 24%"
  credit_days           integer      not null default 15,   -- "if not paid within 15 days"
  jurisdiction          text default 'GUNTUR',
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

create type staff_role as enum
  ('owner','admin','accountant','store_keeper','production_head','chief','driver','sales_exec');

create table staff (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  auth_uid    uuid unique,                     -- auth.users.id
  full_name   text not null,
  phone       text,
  role        staff_role not null default 'sales_exec',
  daily_wage  numeric(12,2) default 0,
  is_mestry   boolean not null default false,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index on staff(org_id, role);

-- ------------------------------------------------------------
-- 1. MASTERS — routes, customers
-- ------------------------------------------------------------
create table routes (
  id        uuid primary key default gen_random_uuid(),
  org_id    uuid not null references orgs(id) on delete cascade,
  name      text not null,
  towns     text[] default '{}',
  is_active boolean not null default true,
  unique (org_id, name)
);

create table customers (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  code           text,                       -- auto S.No / ledger code
  name           text not null,              -- name / company name
  mobile1        text,
  mobile2        text,
  mobile3        text,
  town           text,                       -- city / town
  address        text,
  route_id       uuid references routes(id),
  price_group    text default 'default',     -- for rate-difference handling
  credit_limit   numeric(14,2) default 0,
  opening_balance numeric(14,2) not null default 0,  -- +ve = customer owes
  whatsapp_opt_in boolean not null default true,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (org_id, code)
);
create index on customers(org_id, town);
create index on customers(org_id, route_id);
create index customers_name_trgm on customers using gin (name gin_trgm_ops);

-- Supplier master (raw material purchase)
create table suppliers (
  id        uuid primary key default gen_random_uuid(),
  org_id    uuid not null references orgs(id) on delete cascade,
  name      text not null,
  mobile1   text,
  town      text,
  opening_balance numeric(14,2) not null default 0,
  is_active boolean not null default true
);

-- ------------------------------------------------------------
-- 2. INVENTORY MASTERS
--    Finished goods use jar/box maths: 1 box = units_per_box jars,
--    1 jar = pieces_per_unit pieces.  Raw materials use kg/ltr.
-- ------------------------------------------------------------
create type item_type as enum ('finished_good','raw_material','packing_material');
-- ------------------------------------------------------------
-- CONFIGURABLE LOOKUPS
-- Nothing below is hard-coded. Every one of these is created and
-- edited by the client from the CRM's Setup screens.
-- ------------------------------------------------------------

-- How a quantity converts. The four bases are structural (they describe
-- the actual physical relationship); the codes and names on top of them
-- are the client's to define.
create type uom_basis as enum ('box','unit','piece','weight');

create table uoms (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  code       text not null,              -- 'BOX','JAR','PACK','TRY','KG','GM','PC'
  name       text not null,
  basis      uom_basis not null,
  weight_g   numeric(12,3),              -- for basis='weight': grams per 1 of this uom
  sort_order integer not null default 0,
  is_active  boolean not null default true,
  unique (org_id, code)
);

-- The client's "Pack" column — purely a label on reports and prints.
create table pack_types (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  code       text not null,              -- 'JAR','PACK','L.B','KG','TRY','BOX'
  name       text,
  sort_order integer not null default 0,
  is_active  boolean not null default true,
  unique (org_id, code)
);

-- Receipt / payment modes. Client-defined, so BSR and BRK are rows,
-- not enum values we have to guess the meaning of.
create table receipt_modes (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  code          text not null,           -- 'CASH','BANK','BSR','BRK','UPI','CHEQUE'
  name          text not null,
  is_collection boolean not null default true,   -- false = deduction head
  needs_reference boolean not null default false,-- cheque no / UTR / slip no
  sort_order    integer not null default 0,
  is_active     boolean not null default true,
  unique (org_id, code)
);

create table expense_heads (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  name       text not null,
  is_active  boolean not null default true,
  unique (org_id, name)
);

-- Document numbering — prefix, width, reset rule, all editable.
create table number_series (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  doc_type     text not null,            -- 'invoice','receipt','purchase','return','batch','payment'
  prefix       text default '',
  suffix       text default '',
  width        integer not null default 4,
  next_number  bigint  not null default 1,
  reset_period text not null default 'never',  -- never | yearly | monthly | daily
  last_reset   date,
  unique (org_id, doc_type)
);

-- Module-level permissions per role, editable by the owner.
create table role_permissions (
  id        uuid primary key default gen_random_uuid(),
  org_id    uuid not null references orgs(id) on delete cascade,
  role      staff_role not null,
  module    text not null,               -- 'items','invoices','receipts','production',…
  can_view  boolean not null default false,
  can_edit  boolean not null default false,
  can_delete boolean not null default false,
  unique (org_id, role, module)
);

-- In-app data import (replaces running a script by hand).
create type import_status as enum ('uploaded','mapped','previewed','committed','failed');

create table import_jobs (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  target       text not null,            -- 'items','customers','opening_stock','rates'
  file_path    text,                     -- Supabase Storage
  column_map   jsonb,
  total_rows   integer default 0,
  ok_rows      integer default 0,
  error_rows   jsonb default '[]',
  status       import_status not null default 'uploaded',
  created_by   uuid references staff(id),
  created_at   timestamptz not null default now()
);


-- Production sections from the stock report (S-1 … S-13, plus unnumbered
-- groups like OTHERS (UNDALU) and R.K.BAKERY). Each is run by a mestri and
-- the stock report is grouped and sub-totalled by these.
create table sections (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  code       text,                       -- 'S-10', 'S-7', null for OTHERS/R.K.BAKERY
  name       text not null,              -- 'RAMA KRISHNA MESTRI', 'CHIKKI RAKALU (SUNIL)'
  mestri_id  uuid references staff(id),
  sort_order integer not null default 0, -- print order on the stock report
  is_active  boolean not null default true,
  unique (org_id, name)
);

create table item_categories (
  id     uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  name   text not null,
  unique (org_id, name)
);

create table items (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  item_code      text not null,
  name           text not null,
  category_id    uuid references item_categories(id),
  section_id     uuid references sections(id),      -- mestri section, drives stock report grouping
  type           item_type not null default 'finished_good',
  pack_type_id   uuid references pack_types(id),    -- client's "Pack" column

  -- stock is ALWAYS held in base_uom; everything else converts to it
  base_uom_id     uuid references uoms(id),         -- stock is held in this uom

  -- Packing, read straight off the price list. NOT a fixed 8 — the master
  -- has 6, 8, 11, 12, 15, 20, 21, 22, 24, 25, 30, 32, 40, 48, 50, 60.
  units_per_box   integer not null default 8,     -- price list "BOX" column: N x 1
  pieces_per_unit integer not null default 1,     -- the "(12)" inside the item name
  mrp_per_piece   numeric(10,2),                  -- the "5/-" / "2/-" / "1/-" prefix
  net_weight_g    numeric(12,3),                  -- for KG-pack items

  unit_rate       numeric(12,2) not null default 0,  -- rate per JAR / PACK / L.B unit
  box_rate        numeric(12,2)
                  generated always as (unit_rate * units_per_box) stored,
  purchase_rate  numeric(12,2) default 0,
  mrp            numeric(12,2),


  reorder_level  numeric(14,3) default 0,
  shelf_life_days integer,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (org_id, item_code)
);
create index on items(org_id, type);
create index items_name_trgm on items using gin (name gin_trgm_ops);

-- Customer-specific / group-specific rate overrides (rate difference handling)
create table item_price_overrides (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  item_id     uuid not null references items(id) on delete cascade,
  price_group text,
  customer_id uuid references customers(id) on delete cascade,
  unit_rate    numeric(12,2) not null,
  valid_from  date not null default current_date,
  valid_to    date
);

-- ------------------------------------------------------------
-- 3. STOCK LOCATIONS  (godown + every vehicle is a location)
-- ------------------------------------------------------------
create type location_kind as enum ('godown','vehicle','production_floor');

create table stock_locations (
  id        uuid primary key default gen_random_uuid(),
  org_id    uuid not null references orgs(id) on delete cascade,
  name      text not null,
  kind      location_kind not null default 'godown',
  is_active boolean not null default true,
  unique (org_id, name)
);

-- ------------------------------------------------------------
-- 4. VEHICLE MANAGEMENT  (Module 6)
-- ------------------------------------------------------------
create table vehicles (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  vehicle_number text not null,
  owner_name     text,
  driver_id      uuid references staff(id),
  route_id       uuid references routes(id),
  capacity_boxes integer,
  location_id    uuid references stock_locations(id),  -- its van-stock location
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (org_id, vehicle_number)
);

create type trip_status as enum ('planned','loaded','dispatched','settled','cancelled');

create table vehicle_trips (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  vehicle_id  uuid not null references vehicles(id),
  route_id    uuid references routes(id),
  driver_id   uuid references staff(id),
  trip_date   date not null default current_date,
  status      trip_status not null default 'planned',
  opening_km  numeric(10,1),
  closing_km  numeric(10,1),
  expenses    numeric(12,2) default 0,
  notes       text,
  created_at  timestamptz not null default now()
);
create index on vehicle_trips(org_id, trip_date);

-- ------------------------------------------------------------
-- 5. STOCK LEDGER — single source of truth for all movement
-- ------------------------------------------------------------
create type stock_txn_type as enum (
  'opening','purchase','purchase_return','production_in','production_consume',
  'sale','sale_return','van_load','van_unload','transfer','damage','adjustment'
);

create table stock_ledger (
  id          bigserial primary key,
  org_id      uuid not null references orgs(id) on delete cascade,
  item_id     uuid not null references items(id),
  location_id uuid not null references stock_locations(id),
  txn_type    stock_txn_type not null,
  txn_date    date not null default current_date,
  qty_base    numeric(16,3) not null,   -- +in / -out, ALWAYS in item.base_uom
  rate        numeric(12,2) default 0,
  ref_table   text,
  ref_id      uuid,
  batch_no    text,
  created_by  uuid references staff(id),
  created_at  timestamptz not null default now()
);
create index on stock_ledger(org_id, item_id, location_id, txn_date);
create index on stock_ledger(ref_table, ref_id);

-- ------------------------------------------------------------
-- 6. PURCHASE
-- ------------------------------------------------------------
create table purchases (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  bill_no        text,
  supplier_id   uuid references suppliers(id),
  location_id   uuid not null references stock_locations(id),
  bill_date     date not null default current_date,
  subtotal      numeric(14,2) not null default 0,
  other_charges numeric(14,2) not null default 0,
  total         numeric(14,2) not null default 0,
  paid_amount   numeric(14,2) not null default 0,
  notes         text,
  created_by    uuid references staff(id),
  created_at    timestamptz not null default now()
);

create table purchase_items (
  id          uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references purchases(id) on delete cascade,
  item_id     uuid not null references items(id),
  qty         numeric(16,3) not null,
  uom_id      uuid not null references uoms(id),
  qty_base    numeric(16,3) not null,   -- converted
  rate        numeric(12,2) not null default 0,
  amount      numeric(14,2) not null default 0
);

-- ------------------------------------------------------------
-- 7. SALES / INVOICE  (Module 1: purchase/sale)
-- ------------------------------------------------------------
create type invoice_status as enum ('draft','confirmed','dispatched','delivered','cancelled');

create table invoices (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  invoice_no    text not null,
  customer_id   uuid not null references customers(id),
  invoice_date  date not null default current_date,
  location_id   uuid not null references stock_locations(id), -- godown or van
  vehicle_id    uuid references vehicles(id),   -- assigned AFTER creation
  trip_id       uuid references vehicle_trips(id),
  status        invoice_status not null default 'draft',
  subtotal      numeric(14,2) not null default 0,
  discount      numeric(14,2) not null default 0,
  round_off     numeric(8,2) not null default 0,
  total         numeric(14,2) not null default 0,
  notes         text,
  created_by    uuid references staff(id),
  created_at    timestamptz not null default now(),
  unique (org_id, invoice_no)
);
create index on invoices(org_id, customer_id, invoice_date);
create index on invoices(org_id, vehicle_id, invoice_date);

create table invoice_items (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references invoices(id) on delete cascade,
  item_id     uuid not null references items(id),
  -- Matches the quotation layout: Jars | Boxes | Qty | Rate | Total
  units_per_box numeric(12,3) not null default 1,  -- "Jars" col, snapshot at billing
  boxes         numeric(16,3) not null default 0,  -- "Boxes" col — what the user types
  qty           numeric(16,3) not null,            -- "Qty"  = boxes * units_per_box
  uom_id        uuid references uoms(id),
  qty_base      numeric(16,3) not null,
  rate          numeric(12,2) not null,            -- rate per UNIT (jar/pack), not per box
  amount        numeric(14,2) not null default 0   -- qty * rate
);

-- ------------------------------------------------------------
-- 8. RETURNS  (fresh return / rate difference / damaged return)
-- ------------------------------------------------------------
create type return_kind as enum ('fresh_return','rate_difference','damage_return');

create table sales_returns (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  return_no   text,
  customer_id uuid not null references customers(id),
  invoice_id  uuid references invoices(id),
  return_date date not null default current_date,
  kind        return_kind not null,
  location_id uuid references stock_locations(id),  -- null for rate_difference
  total       numeric(14,2) not null default 0,
  notes       text,
  created_by  uuid references staff(id),
  created_at  timestamptz not null default now()
);

create table sales_return_items (
  id         uuid primary key default gen_random_uuid(),
  return_id  uuid not null references sales_returns(id) on delete cascade,
  item_id    uuid not null references items(id),
  qty        numeric(16,3) not null default 0,   -- boxes/jars returned
  uom_id     uuid references uoms(id),
  qty_base   numeric(16,3) not null default 0,
  old_rate   numeric(12,2),      -- for rate_difference
  new_rate   numeric(12,2),
  amount     numeric(14,2) not null default 0
);

-- ------------------------------------------------------------
-- 9. RECEIPTS & PAYMENTS  (Module 1)
--    Mirrors the client's register: cash / bank / BSR / BRK
-- ------------------------------------------------------------

create table receipts (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  receipt_no   text,
  customer_id  uuid not null references customers(id),
  receipt_date date not null default current_date,
  vehicle_id   uuid references vehicles(id),
  trip_id      uuid references vehicle_trips(id),
  total_amount numeric(14,2) not null default 0,
  narration    text,
  created_by   uuid references staff(id),
  created_at   timestamptz not null default now()
);
create index on receipts(org_id, customer_id, receipt_date);

create table receipt_lines (
  id          uuid primary key default gen_random_uuid(),
  receipt_id  uuid not null references receipts(id) on delete cascade,
  mode_id     uuid not null references receipt_modes(id),
  amount      numeric(14,2) not null default 0,
  reference   text                       -- cheque no / UTR / BSR slip no
);

-- Allocation of a receipt against specific invoices (FIFO by default)
create table receipt_allocations (
  id         uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references receipts(id) on delete cascade,
  invoice_id uuid not null references invoices(id),
  amount     numeric(14,2) not null
);

-- Payments to suppliers / expenses
create table payments (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  payment_no   text,
  supplier_id  uuid references suppliers(id),
  staff_id     uuid references staff(id),
  expense_head_id uuid references expense_heads(id),
  payment_date date not null default current_date,
  mode_id      uuid references receipt_modes(id),
  amount       numeric(14,2) not null,
  reference    text,
  narration    text,
  created_by   uuid references staff(id),
  created_at   timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 10. PRODUCTION  (Module 5)
--     Formula per item -> per PLATE, expected pieces/boxes,
--     chief's actual usage, and the daily difference.
-- ------------------------------------------------------------
create table recipes (
  id                 uuid primary key default gen_random_uuid(),
  org_id             uuid not null references orgs(id) on delete cascade,
  item_id            uuid not null references items(id) on delete cascade,
  name               text,
  pieces_per_plate   numeric(12,3) not null default 0,  -- expected output
  is_active          boolean not null default true,
  created_at         timestamptz not null default now()
);

create table recipe_ingredients (
  id             uuid primary key default gen_random_uuid(),
  recipe_id      uuid not null references recipes(id) on delete cascade,
  ingredient_id  uuid not null references items(id),   -- type = raw_material
  qty_per_plate  numeric(16,4) not null,
  uom_id         uuid references uoms(id)
);

create type batch_status as enum ('open','closed','cancelled');

create table production_batches (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references orgs(id) on delete cascade,
  batch_no          text,
  item_id           uuid not null references items(id),
  recipe_id         uuid references recipes(id),
  production_date   date not null default current_date,
  no_of_plates      numeric(12,3) not null default 0,

  expected_pieces   numeric(16,3) not null default 0,   -- plates * pieces_per_plate
  expected_jars     numeric(16,3) not null default 0,   -- pieces / pieces_per_unit
  expected_boxes    numeric(16,3) not null default 0,   -- jars / units_per_box
  actual_pieces     numeric(16,3) not null default 0,
  actual_jars       numeric(16,3) not null default 0,
  actual_boxes      numeric(16,3) not null default 0,

  no_of_workers     integer not null default 0,
  mestry_count      integer not null default 0,
  labour_count      integer not null default 0,
  labour_cost       numeric(14,2) not null default 0,
  chief_id          uuid references staff(id),

  location_id       uuid references stock_locations(id),
  status            batch_status not null default 'open',
  notes             text,
  created_by        uuid references staff(id),
  created_at        timestamptz not null default now()
);
create index on production_batches(org_id, production_date, item_id);

-- This is the table the doc asks for, one row per ingredient
create table batch_ingredients (
  id              uuid primary key default gen_random_uuid(),
  batch_id        uuid not null references production_batches(id) on delete cascade,
  ingredient_id   uuid not null references items(id),
  qty_per_plate   numeric(16,4) not null default 0,
  no_of_plates    numeric(12,3) not null default 0,
  expected_qty    numeric(16,4) not null default 0,  -- qty_per_plate * plates
  actual_qty      numeric(16,4) not null default 0,  -- "total used by chief"
  difference      numeric(16,4)
                  generated always as (actual_qty - expected_qty) stored,
  rate            numeric(12,2) not null default 0,
  amount          numeric(14,2) not null default 0,
  uom_id          uuid references uoms(id)
);

-- ------------------------------------------------------------
-- 11. INTEGRATIONS / REMINDERS / CATALOGS  (Modules 3 & 4)
-- ------------------------------------------------------------
create type channel_kind as enum ('whatsapp','sms','ivr_call','email');
create type msg_purpose  as enum
  ('payment_reminder','new_stock','catalog','order_ack','invoice','delivery','custom');

create table message_templates (
  id        uuid primary key default gen_random_uuid(),
  org_id    uuid not null references orgs(id) on delete cascade,
  name      text not null,
  channel   channel_kind not null default 'whatsapp',
  purpose   msg_purpose not null,
  provider_template_name text,          -- WhatsApp Cloud API template id
  language  text default 'te',
  body      text not null,              -- with {{1}} {{2}} placeholders
  is_active boolean not null default true
);

create type msg_status as enum ('queued','sent','delivered','read','failed');

create table message_log (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  customer_id  uuid references customers(id),
  template_id  uuid references message_templates(id),
  channel      channel_kind not null default 'whatsapp',
  purpose      msg_purpose not null,
  to_number    text not null,
  payload      jsonb,
  status       msg_status not null default 'queued',
  provider_msg_id text,
  error        text,
  sent_at      timestamptz,
  created_at   timestamptz not null default now()
);
create index on message_log(org_id, customer_id, created_at desc);

create table reminder_rules (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  name           text not null,
  purpose        msg_purpose not null default 'payment_reminder',
  template_id    uuid references message_templates(id),
  min_outstanding numeric(14,2) default 1,
  overdue_days   integer default 7,
  run_cron       text default '0 10 * * *',   -- 10:00 IST daily
  is_active      boolean not null default true
);

create table catalogs (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  name        text not null,
  pdf_url     text,
  item_ids    uuid[] default '{}',
  valid_from  date default current_date,
  valid_to    date,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- Inbound orders captured from WhatsApp / calls, before becoming an invoice
create type order_source as enum ('whatsapp','call','manual','app');
create type order_status as enum ('new','confirmed','invoiced','rejected');

create table inbound_orders (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  customer_id  uuid references customers(id),
  raw_text     text,
  audio_url    text,
  parsed_items jsonb,           -- [{item_code, qty, uom}]
  source       order_source not null default 'whatsapp',
  status       order_status not null default 'new',
  invoice_id   uuid references invoices(id),
  created_at   timestamptz not null default now()
);
create index on inbound_orders(org_id, status, created_at desc);

-- ------------------------------------------------------------
-- 12. ATTENDANCE (light, ports from Punchly)
-- ------------------------------------------------------------
create type attend_status as enum ('present','absent','half_day','leave','holiday');

create table attendance (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  staff_id   uuid not null references staff(id) on delete cascade,
  work_date  date not null,
  status     attend_status not null default 'present',
  in_time    time,
  out_time   time,
  ot_hours   numeric(6,2) default 0,
  wage_amount numeric(12,2) default 0,
  unique (staff_id, work_date)
);

-- ------------------------------------------------------------
-- 13. AUDIT
-- ------------------------------------------------------------
create table audit_log (
  id         bigserial primary key,
  org_id     uuid,
  actor      uuid,
  action     text,
  table_name text,
  row_id     text,
  before     jsonb,
  after      jsonb,
  created_at timestamptz not null default now()
);
