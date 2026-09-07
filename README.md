# Jyothi Foods ERP

ERP for a traditional sweets & namkeen manufacturer (Andhra Pradesh / Telangana).
Accounting · stock · production · vehicles · staff · customer messaging.

## Start here

1. **`DOMAIN_RULES.md`** — read first. Domain rules, stack, conventions, what not to do.
2. **`docs/BUILD_TASKS.md`** — sequenced tasks, in order, with acceptance criteria.
3. **`docs/PROJECT_PLAN.md`** — full functional spec, module by module.
4. **`docs/reference/`** — the client's original files. Check work against these.

## Setup

```bash
npm install
cp .env.example .env          # add Supabase URL + anon key, Nikki API key
```

Apply migrations, run the DB acceptance tests, then generate types:

```bash
DATABASE_URL=postgresql://... db/apply.sh   # 01 → 02 → 04 → 03 → 05, then db/tests/*.sql
npm run gen:types                            # regenerates src/types/supabase.ts
```

**Order matters:** `03_rls.sql` enables policies on tables that `04_extended.sql`
creates, so 04 runs before 03. If you paste into the Supabase SQL Editor instead of
using `psql`, paste each file as one query, in that same order, then run the tests.

`src/types/supabase.ts` is generated and committed; regenerate it after every
migration (see `src/types/README.md`).

Seed the client's real master data through the in-app importer (T0.5) from
`seed/*.csv`. `scripts/import_masters.py` only regenerates those CSVs from the
spreadsheets in `docs/reference/`.

```bash
npm run dev          # http://localhost:5173
npm run typecheck    # tsc -b --noEmit
npm run lint         # eslint .
npm test             # vitest — lib maths checked against the client's quotation
npm run build        # production build
```

## Layout

```
db/         numbered migrations — run in order, never edit a shipped one
scripts/    importers and data tools
seed/       generated master data from the client's spreadsheets
docs/       plan, task list, client reference files
supabase/   edge functions
src/
  app/        routes, layout, providers, nav
  features/   one folder per domain — api.ts · schema.ts · components/ · routes/
  components/ shared UI only (shadcn/ui under components/ui)
  hooks/      shared hooks (use-toast)
  lib/        supabase client · format (₹, Indian grouping, DD-MM-YYYY) ·
              units (boxes ↔ units ↔ pieces, invoice line maths) · money (amount in words)
  types/      generated Supabase types
```

## Status

| Task | State |
|---|---|
| T0.1 Scaffold | ✅ Vite + React 18 + TS strict, Tailwind + shadcn/ui, TanStack Query, react-hook-form + zod, react-router. Build clean, shell boots. |
| T0.2 Database | ✅ Migrations 01→02→04→03→05→06 validated on Postgres 16 by `db/tests/*.sql`; types generated. Apply to the Supabase project with `db/apply.sh` or the SQL Editor. |
| T0.3 Auth + shell | ✅ Email/password login, `/welcome` first-run bootstrap, sidebar filtered by `role_permissions`, and RLS that hides Production/Payments from a `sales_exec` (`db/tests/03_permissions.sql`). |
| T0.4 Setup wizard | ✅ `/setup/wizard` — business & trade terms → units → pack types → receipt modes → expense heads → users → sections → locations → numbering → permissions. Each is also a Setup tab with full CRUD and Excel export. Adding a receipt mode adds a register column (`receipts_register()` returns `by_mode`). |
| T0.5 Importer | ✅ Setup → Import data: upload XLSX/CSV → map columns → dry run → error rows download → commit. Targets: sections, items, customers, opening stock, rates. Server-side `import_rows()` (`db/07_import.sql`), one sub-transaction per row, idempotent on natural keys, opening stock re-import posts adjustments never overwrites. |
| T0.6 Client data | ✅ The decoded spreadsheets ship in `public/seed/` and appear as "Use this" buttons in the importer. `db/tests/04_import.sql` loads them exactly as the screen does: 15 sections, 166 price-list items, 21 of the 85 stock-report-only codes (the 64 without a readable packing come back as error rows for the client), and 167 of the 237 opening rows. The 70 rejected opening rows are the 62 codes still missing packing plus four codes the sheet lists twice (27C, 119A, 251, 252 — the importer refuses to guess whether to add them). 3 of the sheet's 7 negative rows show on the closing stock report; the other 4 belong to codes awaiting packing. Rates stay blank until the client supplies them. |

| T1 Masters | ✅ `db/08_masters.sql` drops the `units_per_box` default of 8 and adds list views. **Items**: Add Product with the live derived panel (box rate, pieces per box, worked preview), packing locked once stock has moved, paged list with search / section / pack filters and Excel. **Customers**: CRUD with mobile-1 duplicate check (form and unique index), outstanding on the list, bulk import link. **Vehicles**: create auto-creates the van's stock location. **Setup**: routes, drag-to-reorder sections. `db/tests/05_masters.sql`. |

| T2 Transactions | ✅ `db/09_transactions.sql`: one `save_*` RPC per document that numbers it, posts stock via the 05 functions and writes a balanced journal entry to a seeded system chart of accounts (rule 11, brought forward from T7.3). **Invoice** screen in the quotation's column order, CODE → Boxes → Rate keyboard entry, status machine draft → confirmed → dispatched → delivered, cancel reverses stock and journal, vehicle assigned after creation, A4 print with terms from `orgs` and amount in words. **Purchases** (+ suppliers tab) post stock in on save. **Returns**: one screen, three kinds; rate difference never touches stock. **Receipts**: multi-mode lines, FIFO allocation with manual override. **Payments**: supplier / wages / expense head. `db/tests/06_transactions.sql` reproduces the quotation (17 lines, 32 boxes, 753 qty, ₹34,258.00) and asserts the trial balance is zero after every step. |

| T3 Stock & vehicles | ✅ `db/10_stock_trips.sql`. **Stock**: closing stock by date / location / section, grouped with sub-totals in boxes, negatives flagged, inward and outward counted from every movement type; per-item movement ledger with document references and running balance; low stock by reorder level; all with Excel. **Trips**: create → load (godown → van through the ledger) → dispatch → settle; invoices booked on a trip sell from the van; settlement shows loaded vs sold vs returned vs collected with the gap per item; printable loading sheet. `db/tests/07_stock_trips.sql`. |

| T4 Production | ✅ `db/11_production.sql`. **Recipes** per item (qty per plate, pieces per plate; one active per item). **Batch open** explodes the recipe into expected usage and `plates × pieces per plate → ÷ pieces per unit → ÷ units per box` expected boxes. **Sheet** in the client's exact columns: Ingredients · Quantity · No of Plates · Total Usage per Plate · Total Used by Chief · Difference · No of Workers · Mestry · Labour, plus Expected vs Actual Boxes. **Chief** enters actuals and, by RLS, sees only today's open batch; the production head closes. **Close** consumes raw material, adds finished goods at cost, costs the batch (ingredients + labour, cost per box). **Variance** by item, mestri or week. `db/tests/08_production.sql`. |

| T5 Dashboard & reports | ✅ `db/12_reports.sql`. **Dashboard**: sales today / month, collection, live outstanding, low and negative stock, vehicles out, open batches — each a SUM over the live tables, each a link into its screen; the day's activity feed across every document type; the pending order queue (fed by T6). **Accounts**: the receipts & payments register in the client's exact columns (S.No · Name · Town · Total Outstanding · one column per active receipt mode · Fresh Return · Rate Difference · Return · Remaining Outstanding), with Remaining tied to the live outstanding; customer ledger with opening and running balance; ageing 0–15 / 16–30 / 31–60 / 60+ after FIFO; collection by mode; route-wise sales, collection and outstanding. **Sales**: daily, monthly, customer-, town-, route-, item- and section-wise. Every report has a route/date filter, Excel and a print view. `db/tests/09_reports.sql`. |

**Still needed from the client to finish T0.6:** units per box (and pack type) for the 64 codes in
`seed/unmatched_items.csv` with a blank `units_per_box`, the four duplicated stock-sheet rows resolved,
and the rate list. Each is a re-run of the importer, not a developer task.

Deploy the `create-user` edge function before adding users from Setup:

```bash
supabase functions deploy create-user
```

Then disable public sign-ups in the Supabase dashboard (Authentication → Providers → Email). The owner
signs up once, lands on `/welcome`, creates the org, and every later login is created from Setup → Users.
