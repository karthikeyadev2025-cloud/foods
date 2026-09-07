# BUILD_TASKS.md

Sequenced work, in build order. **Do them in order** — each depends on the one before.
Finish a task completely (definition of done in `DOMAIN_RULES.md`) before starting the next.
One task = one commit = one PR-sized change.

---

## T0 — Foundation

**T0.1 Scaffold**
Vite + React 18 + TypeScript strict, Tailwind, shadcn/ui, TanStack Query,
react-hook-form + zod, react-router. Folder layout exactly as in `DOMAIN_RULES.md`.
`lib/supabase.ts`, `lib/format.ts` (Indian number grouping, ₹, dates as `DD-MM-YYYY`),
`lib/units.ts` (boxes ↔ units ↔ pieces).
✅ `npm run build` clean, zero TS errors, app boots to an empty shell.

**T0.2 Database**
Apply `db/01_schema.sql`, `db/02_logic.sql`, `db/03_rls.sql` in order.
Generate types into `src/types/supabase.ts`.
✅ All tables exist, RLS on, types compile.

**T0.3 Auth + shell**
Supabase email/password login. `useSession`, `useStaff` (role + org). App shell:
sidebar nav filtered by role, top bar, org name. Protected routes.
✅ A `sales_exec` account cannot see the Production or Payments nav items, and hitting
those URLs directly is blocked by RLS, not just the router.

**T0.4 Setup wizard + configuration screens**
First run of an empty database must be completable by the client, with no SQL.
Wizard: org + trade terms (breakage %, interest %, credit days, jurisdiction) → **UOMs**
(code, name, basis) → **pack types** → **receipt modes** (collection vs deduction, needs
reference) → **expense heads** → **sections + mestris** → **stock locations** →
**number series** per document type → first users and role permissions.
Each step is also a standalone Setup screen afterwards, with full CRUD.
✅ A brand-new org can be configured end to end through the UI alone.
✅ Adding a receipt mode in Setup makes a new column appear in the receipts register
with no code change.

**T0.5 In-app data import**
Generic importer backed by `import_jobs`: upload XLSX/CSV → map columns → dry-run preview
→ commit, with error rows downloadable. Targets: items, customers, opening stock, rates.
✅ The client can load and update their own master data without a developer.
✅ Re-importing the same file is idempotent.

**T0.6 Load the client's real data — through the importer, not a script**
Use T0.5's importer on `seed/*.csv` (produced from the client's spreadsheets).
Rates left null until the client supplies them.
✅ 15 sections, 166 items, 237 opening rows. Closing-stock report renders grouped by
section and matches `STOCK_REPORT.xlsx` row for row, negatives included.

---

## T1 — Masters

**T1.1 Sections** — CRUD, assign mestri, sort order (drag to reorder).

**T1.2 Items — Add Product is the anchor screen of the whole system**
This is the single place packing and pricing are ever entered. Build it carefully; every
other screen derives from it.

Fields: item code (text), pack type, name, section, `units_per_box`, `pieces_per_unit`,
`mrp_per_piece`, `unit_rate`, `purchase_rate`, reorder level, shelf life.

Live derived panel, all read-only:
- **Box rate** = `unit_rate × units_per_box`
- **Pieces per box** = `pieces_per_unit × units_per_box`
- A worked preview: "1 box = 32 packs = 384 pieces · box rate ₹1,344.00"

List: search across code + name, filter by section and pack type, Excel export.

✅ Changing `unit_rate` updates box rate live, and box rate has no input.
✅ `units_per_box` is required, has no imposed default of 8, and goes **read-only once the
item has any `stock_ledger` row** — with a message pointing the user to create a new code
for a repack (their existing "NEW" convention).
✅ No other screen in the app contains a packing or box-rate input. Grep for it.

**T1.3 Customers**
CRUD with mobile 1–3, town, route, price group, credit limit, opening balance,
WhatsApp opt-in. Duplicate check on mobile1.

**T1.4 Customer bulk import**
CSV/XLSX upload → column mapper → dry-run preview → commit. Error rows download with a
reason per row. Idempotent on mobile1.
✅ Re-importing the same file twice creates no duplicates.

**T1.5 Routes, staff, stock locations, vehicles**
Vehicle create auto-creates its matching `stock_locations` row of kind `vehicle`.

---

## T2 — Transactions

**T2.1 Purchase entry** — supplier, bill, godown, lines, posts inward stock on save.

**T2.2 Sales invoice — the core screen**
Fast keyboard entry: type CODE → tab → Boxes → tab → Rate → Enter adds the row.
Jars, Qty, Total all derived and read-only.
✅ Reproduce the uploaded quotation exactly: 17 lines, 32 total boxes, 753 total qty,
net ₹34,258.00. This is the acceptance test — build against it.

**T2.3 Invoice print**
A4 print layout matching the client's quotation, including the numbered terms footer
pulled from `orgs`, and amount in words (Indian system — "Thirty Four thousand Two
hundred Fifty Eight").

**T2.4 Returns**
One screen, three kinds. Breakage applies `orgs.breakage_recovery_pct`.
Rate difference posts no stock row.
✅ A rate-difference return changes the customer balance and leaves `stock_ledger` untouched.

**T2.5 Receipts**
Multi-mode lines (cash / bank / BSR / BRK / UPI / cheque / adjustment), FIFO allocation
against open invoices with a manual override.

**T2.6 Payments** — suppliers, staff wages, expense heads.

---

## T3 — Stock & vehicles

**T3.1 Stock reports**
Closing stock (date + location, grouped by section, in boxes, negatives flagged),
stock movement ledger per item, low stock. All with Excel export.

**T3.2 Van loading + trips**
Trip create → load lines → stock moves godown → van. Loading sheet print.
Assign vehicle to a confirmed invoice.

**T3.3 Trip settlement**
Loaded vs sold vs returned vs collected, with the gap shown explicitly.

---

## T4 — Production

**T4.1 Recipes** — ingredients with qty per plate, pieces per plate.

**T4.2 Batch open + production sheet**
Open batch → plates → recipe explodes → expected usage and expected boxes.
Sheet columns exactly: `Ingredients · Quantity · No of Plates · Total Usage per Plate ·
Total Used by Chief · Difference · No of Workers · Mestry · Labour`,
plus Expected vs Actual Boxes.

**T4.3 Batch close**
Consumes raw material, adds finished goods, costs the batch. Chief role sees only
today's open batch.

**T4.4 Variance report** — by item, by mestri, by week.

---

## T5 — Dashboard & reports

**T5.1 Dashboard** — `dashboard_summary()` tiles + today's activity + pending order queue.
**T5.2 Accounts reports** — receipts register (client's exact columns), customer ledger,
outstanding ageing 0/15/30/60+, collection by mode, route-wise collection.
**T5.3 Sales reports** — daily/monthly, customer-wise, town-wise, item-wise.

---

## T6 — Hey Nikki integration

**T6.1 Outbound** — `lib/nikki.ts` client, message templates CRUD (Telugu + English),
send + log to `message_log`, `nikki-status` webhook updates delivery state.
**T6.2 Reminder engine** — `reminder_rules` + `run-reminders` edge function on pg_cron,
recipients from `v_customer_outstanding`, escalation ladder, opt-out honoured.
**T6.3 New-stock broadcast** — triggered on production/purchase crossing threshold,
targeted at recent buyers of that item, not the whole list.
**T6.4 Catalogs** — PDF to Storage, push to a segment.
**T6.5 Inbound order queue** — `nikki-inbound` writes to `inbound_orders`; operator screen
shows raw text beside parsed lines, low confidence highlighted, edit then
**Convert to Invoice**. Never automatic.

---

## T7 — Accounting & money

**T7.1 Cash & bank** — accounts (cash in hand, bank), transactions, transfers,
cash book and bank book, balances on the dashboard.
**T7.2 Cheque management** — received and issued, in-hand → deposited → cleared / bounced,
due-date reminders.
**T7.3 Chart of accounts + journal**
Seeded system accounts (Sales, Purchases, Cash, Bank, Debtors, Creditors, Labour,
Raw Material, Breakage), auto-posting from invoice / purchase / receipt / payment /
return / production close, plus manual journal entry.
✅ Trial balance nets to zero on any date range. This is the acceptance test — if it
doesn't balance, the posting rules are wrong and everything downstream is fiction.
**T7.4 Financial reports** — trial balance, P&L, balance sheet, day book, cash flow.
**T7.5 Item profitability** — sale value vs cost, by item, section and period.

## T8 — Documents & pricing

**T8.1 Quotation** — the client's actual starting document. Same line grid as the invoice,
validity date, convert to invoice in one click (nothing re-typed).
**T8.2 Sale & purchase orders** — with partial fulfilment tracking, converted from the
inbound WhatsApp/call queue.
**T8.3 Delivery challan** — goods out before billing, convert to invoice later.
**T8.4 Purchase return / debit note.**
**T8.5 Price lists** — named lists, per-customer assignment, bulk rate update,
effective dates. Replaces ad-hoc overrides.
**T8.6 Discount schemes** — min boxes → discount % or free boxes.

## T9 — Inventory depth

**T9.1 Batches & expiry** — batch on production close, FEFO suggestion on van loading,
expiry alert report.
**T9.2 Barcodes** — generate, print labels, scan into invoice lines (box or jar barcode).
**T9.3 Godown transfers** — location to location, with a transfer note.
**T9.4 Physical stock count** — count sheet, variance, posts adjustment rows.

## T10 — Owner control

**T10.1 Business profile** — single trade name **JYOTHI FOODS**: logo, address, phone,
FSSAI, signature, and the printed trade terms (breakage %, interest %, credit days,
jurisdiction). No multi-firm.
**T10.2 Print designer** — per document type and paper size (A4 / A5 / thermal),
toggle columns and blocks, edit the numbered terms, logo and signature.
**T10.3 Backup & restore** — manual and scheduled, retention, restore with confirmation.
**T10.4 Transaction messages** — per document type, auto-send toggle, template, PDF attach.
**T10.5 Audit log viewer** — who changed what, filterable.
**T10.6 User management** — invite, roles, module permissions matrix, deactivate.

## T11 — Desktop

**T11.1 Electron shell** — same app, signed Windows installer.
**T11.2 Licensing** — key activation against `orgs.license_key` / `license_valid_till`,
periodic recheck. **On lapse the app goes read-only** — view and export still work,
document creation is blocked.
**T11.3 Offline** — read cache, queued writes, sync on reconnect.

---

## T12 — Phase 3 (after client sign-off)

Telugu order-taking calls on the Nikki voice pipeline · driver mobile app (van sales,
on-the-spot receipts, delivery proof) · route profitability · salesman incentives ·
batch/expiry tracking · outbound reminder calls.

---

## Blocked until the client answers

- **T1.2 item rates** — no rate column in either file. Items load without rates.
- **T2.2 invoice** can be built and tested against the quotation, but can't go live
  without rates.
- **87 unmatched items** (`seed/unmatched_items.csv`) need units-per-box and rate.
- **BSR** meaning — affects whether it stays a receipt mode.
