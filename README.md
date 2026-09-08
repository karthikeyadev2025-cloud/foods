# Jyothi Foods ERP

ERP for a traditional sweets & namkeen manufacturer (Andhra Pradesh / Telangana).
Accounting · stock · production · vehicles · staff · customer messaging.

## Start here

1. **`DOMAIN_RULES.md`** — read first. Domain rules, stack, conventions, what not to do.
2. **`docs/BUILD_TASKS.md`** — sequenced tasks, in order, with acceptance criteria.
3. **`docs/PROJECT_PLAN.md`** — full functional spec, module by module.
4. **`docs/reference/`** — the client's original files. Check work against these.
5. **`docs/DEPLOY.md`** — put it on the web (Vercel) · **`docs/DESKTOP.md`** — the Windows installer, offline ·
   **`docs/LICENSING.md`** — the three keys, what each unlocks, and how to issue one ·
   **`docs/INTEGRATIONS.md`** — the two outside services: Hey Nikki and Punchly.

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
electron/   desktop shell (main + preload) — docs/DESKTOP.md
src/
  app/        routes, layout, providers, nav
  features/   one folder per domain — api.ts · schema.ts · components/ · routes/
  components/ shared UI only (shadcn/ui under components/ui)
  hooks/      shared hooks (use-toast, use-offline)
  lib/        supabase client (+ queuedRpc / outbox replay) · offline (outbox store) · desktop bridge ·
              format (₹, Indian grouping, DD-MM-YYYY) · units (boxes ↔ units ↔ pieces, invoice
              line maths) · money (amount in words)
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

| T6 Hey Nikki messaging | ✅ `db/13_messaging.sql` + four edge functions. **Outbound**: templates in Telugu and English (customer language picks one), every message queued in `message_log` and sent by `nikki-send` (switch, quiet hours, daily cap, three attempts), delivery state from the `nikki-status` webhook; automatic invoice copy on dispatch, delivery confirmation, receipt thanks and order acknowledgement, each switchable per document. **Reminders**: rules are the ladder (gentle 7 d → firm 30 d → final 60 d), recipients resolved live from outstanding after credit days, one reminder per customer per repeat window, preview / dry run / run now, `run-reminders` on pg_cron at 10:00. **New stock**: a stock-ledger trigger creates a broadcast for recent buyers when production or a purchase crosses the item's threshold; auto-send or wait for the operator. **Catalogs**: PDF to the `catalogs` bucket, pushed to a route / town / recent buyers with a recipient preview. **Inbound**: `nikki-inbound` matches the customer by mobile, STOP / START flips opt-in, the operator sees the text beside matched lines (code match, name match or not found, low confidence flagged), edits, and presses **Convert to invoice** — never automatic. Opt-out honoured everywhere. `db/tests/10_messaging.sql`. |

| T7 Accounting & money | ✅ `db/14_accounts.sql`. **Cash & bank**: accounts with live balances, every receipt / payment / purchase-paid / transfer / cleared cheque lands in one (a mode can name its account; otherwise cash → Cash in hand, the rest → Bank), cash book and bank book with running balance, transfers, balances on the dashboard. **Cheques**: a cheque mode on a receipt or payment books the cheque (Cheques in hand / Cheques issued) instead of the bank; deposit → cleared moves the money; a bounce writes a reversal receipt or payment so the customer owes again and the bills reopen, with bank charges; due-in-3-days list. **Journal**: nineteen system accounts (renamable, not deletable), every document posts, manual entries with a Cash/Bank line naming the account, reversal rather than edit, general ledger per account. **Reports**: trial balance (range, opening / movement / closing, must net to zero), P&L, balance sheet (ties, with the never-journalled opening balances shown against Opening balance equity), day book, cash flow by head, item profitability by item or section (latest batch cost or purchase rate). `db/tests/11_accounts.sql` asserts the trial balance is zero after every step. |

| T8 Documents & pricing | ✅ `db/15_documents.sql`. **Quotation**: the client's starting form on the invoice grid with a validity date, A4 print, convert to a draft invoice in one click with every line and the transport block carried across. **Orders**: sale and purchase, partial fulfilment (deliver / receive some boxes → a draft invoice or a purchase bill, pending tracked per line, completed when nothing is pending), a WhatsApp / call order can become a sale order instead of an invoice. **Challans**: goods out before billing move stock on save; billing them creates a confirmed invoice at the customer's rates with the challan's stock rows reversed, never edited. **Purchase returns**: debit notes that take stock out, post Dr Creditors / Cr Purchases and reduce the supplier's payable. **Price lists**: named, dated, one default, per-customer (form or assign by route / town), rate grid with Excel, bulk update by % / ₹ / from master / from another list; rate at billing is override → price group → customer's list → default list → master. **Discount schemes**: min boxes → % or free boxes, item beats section beats all; "Apply schemes" on a draft invoice. `db/tests/12_documents.sql`. |

| T9 Inventory depth | ✅ `db/16_inventory.sql`. **Batches & expiry**: closing a production batch creates the item batch with expiry = making date + shelf life; balances are FEFO (whatever left the item is charged to the earliest-expiring batch first); expiry report by days, "expiring this week" on the dashboard; van loading shows which batch to pull per line. **Barcodes**: two EAN-13 codes per finished item (box and unit) with a real check digit, label sheet (3 per row, copies), and scanning into the invoice CODE box adds one box or one jar and accumulates on repeat scans. **Godown transfers**: location to location in one note, two ledger rows per line, printable. **Physical count**: open a sheet per location (optionally a section) with the system figure frozen, print it blank, type counted boxes as you go, post — every difference against the LIVE figure becomes an adjustment row, so sales made while counting are not double-counted. `db/tests/13_inventory.sql`. |

| T10 Owner control | ✅ `db/17_owner.sql`. **Business profile**: logo and signature (public `branding` bucket), tagline, email, bank details, and the app's web address for links in messages. **Print designer**: one template per document (invoice, quotation, challan) — paper A4 / A5 / thermal 80 / thermal 58, every header block and column switchable, the numbered terms editable (placeholders `{breakage}` `{interest}` `{credit_days}` `{jurisdiction}` keep them tied to the profile), header and footer lines, live preview; the three prints share one sheet (`src/components/print/SalesDocPrint.tsx`). **Backup & restore**: `org_snapshot()` is the whole org as one JSON file; `backup-org` stores it in the private `backups` bucket (manual "Back up now", or pg_cron hourly asking `backups_due()` — daily / weekly at a set hour, keep N copies); `restore-backup` puts the org back exactly (rows copied with triggers off, sequences moved, staff logins and the audit trail kept) after the owner types the trade name. **Audit trail**: one trigger on forty masters, settings and document headers writes who / when / what changed (updates keep only the changed fields, secrets never), viewer with date, screen, user, action and text filters and a before / after diff. **Transaction messages**: per-document "attach the document" switch (the message carries the print-page link from the app's web address). **Users**: set a new password for a user (edge function `reset-password`). `db/tests/14_owner.sql` includes a snapshot → mutate → restore round trip. |

| T11 Desktop | ✅ `db/18_licensing.sql`, `electron/`, `docs/DESKTOP.md`. **Shell**: the same build in an Electron window (hash router, relative assets, sandboxed preload with a stable device id, single instance, links open outside); `npm run desktop:dist` makes the NSIS installer, signed when `CSC_LINK` / `CSC_KEY_PASSWORD` are set. **Licensing**: the vendor issues a key with `issue_license()` (only its SHA-256 lives in `orgs.license_key`); owner/admin activates it per device (device limit, owner removes devices); `license_status()` is checked at start, on focus and every 30 min; trial → active → grace → expired, and past the grace days the app is **read-only** — every screen, report and export works, every edit right is off in the UI, and `enforce_license()` blocks new documents in the database itself (service role exempt). **Offline**: the query cache is persisted to IndexedDB so screens already seen open without a connection; document saves that cannot reach the server go to an outbox and are replayed in order when the connection returns (automatic, or "Send now"), with rejected items kept for retry or discard. `db/tests/15_licensing.sql`. |

| T12a Phase 3 (no client input needed) | ✅ `db/19_phase3.sql`. **Route profitability** (Reports → Route profit): per route, sales less returns less cost of goods (latest batch cost, else purchase rate) less trip expenses and driver wages, with km, ₹ per km and collection; a van sale belongs to the trip's route, a godown sale to the customer's. **Salesman incentives**: a salesman per customer (form, or a whole route under Setup → Incentives), stamped on every bill and receipt; schemes on % of net sales, % of collection, ₹ per box, ₹ per new shop, or a slab by monthly net sales; the monthly statement per salesman under Reports → Incentives, paid through the usual staff payment. **Driver's phone** (`/m`, installable from the browser, drivers land there on sign-in): today's trip with loaded / sold / collected / stops visited, the stops on the route with live outstanding, a van bill in three taps at the customer's rates (confirmed at once, stock leaves the van), on-the-spot receipts against the oldest bills, delivery proof with a photo into the private `proofs` bucket, van stock left; offline it uses the outbox like the desktop. `db/tests/16_phase3.sql`. |

| T12b Voice calls | ✅ `db/20_voice.sql`. Calls ride the same queue as WhatsApp (`message_log`, channel `ivr_call`) with the same switch, quiet hours and daily cap, plus their own switch, caller number, voice, retry count and delay (Messaging → Settings). **Scripts**: a template with channel "Voice call" is read out by Hey Nikki's Telugu / English voice; a call only ever picks a call script, a text never does. **Reminder calls**: a reminder rule on channel "Voice call" rings instead of texting; the customer presses 1 (will pay this week → a promise date on the customer that holds every reminder until it passes), 2 (already paid) or 3 (call me back); unanswered or busy calls retry after the set delay, then fail; duration, keys, transcript and recording show on the Log. **Order-taking calls**: Broadcasts → "Call for orders" rings a route / town / recent buyers with the order script (it mentions their last bill's items); what the bot hears comes back through `nikki-inbound` with our call id, lands in the Orders queue linked to the call, and is confirmed by a person as always. Edge functions `nikki-send`, `nikki-status` and `nikki-inbound` speak the voice shape in `supabase/functions/_shared/nikki.ts`, which is the ERP's best guess until Hey Nikki's voice docs arrive — only that file and the two webhooks change then. `db/tests/17_voice.sql`. |

| T13 Attendance & Punchly | ✅ `db/22_attendance.sql`. **The register** (Attendance): one row per person per day — first check-in, last check-out, hours, overtime, status and the day's wage — with a "days to check" filter for anything odd, and a **Days & wages** sheet totalling present / half / absent / leave, hours, overtime and what each person is owed for the period (printable and to Excel). Any day can be typed or corrected by hand, and a row touched by hand is never overwritten by a later sync. **Punchly** (Setup → Attendance): the phone app the staff punch on, read every half hour by the `punchly-sync` edge function — Punchly has no webhooks, so it is polled. Punches fold into days in `upsert_punchly_attendance()`, grouped on Punchly's IST `attendance_date` (grouping on the UTC timestamp would put a night shift on the wrong day); the length of a full day is settable, shorter days become half days, and anything under the flag hour, missing a check-out or punched outside the geofence is marked to check. The wage follows `staff.daily_wage` — full day, half for half — unless that is switched off. Yesterday is re-read on every run, because a phone out of signal delivers this morning's punch tonight; every fortnight one run re-reads the whole window, to catch a day an admin corrected in Punchly afterwards; and entering a history date backfills the past a quarter at a time behind a marker that resumes where a failed run stopped. Punchly's errors are acted on by their code, not their wording — a revoked or expired key is reported to the owner instead of being retried for ever, and a rate limit that asks for most of an hour is left to the next run rather than waited out. An employee can be **erased** (owner only): their days go and their Punchly link goes with them, so the next sync cannot fetch them back. People are tied on Punchly's `user_id` (its `staff_id` can be renamed by whoever runs Punchly), linked automatically on one unambiguous name and by hand otherwise — an unmatched person is skipped, and matching them later brings their whole history in on the next read. The key is a server-side secret: `punchly_settings` has no policy for signed-in users at all, and the screen only ever sees its last four characters. GPS comes with every punch and is kept, because the client wants to see where a van salesman punched from; switching it off drops it on the way in and erases what was already stored as those days are read again (DPDP Act). Attendance is a **Growth** feature. `db/tests/19_attendance.sql`. |

**Still needed from the client to finish T0.6:** units per box (and pack type) for the 64 codes in
`seed/unmatched_items.csv` with a blank `units_per_box`, the four duplicated stock-sheet rows resolved,
and the rate list. Each is a re-run of the importer, not a developer task.

Deploy the `create-user` edge function before adding users from Setup:

```bash
supabase functions deploy create-user
```

For Hey Nikki messaging (T6): deploy the four functions, create a public storage bucket named
`catalogs`, then run `db/cron/schedule.sql` in the SQL Editor (it needs the service-role key in
Vault; the file says how). Paste the two webhook addresses and the secret from Messaging →
Settings into the Hey Nikki console, and the API key from Hey Nikki into the same screen.

```bash
supabase functions deploy nikki-send run-reminders
supabase functions deploy nikki-inbound nikki-status --no-verify-jwt
```

For attendance (T13): deploy `punchly-sync`, then paste the Punchly API key into Setup → Attendance
and switch it on. `db/cron/schedule.sql` reads it twice an hour. The key needs the `attendance:read`
and `staff:read` scopes; there is nothing to configure on the Punchly side, because the ERP only reads.

```bash
supabase functions deploy punchly-sync
```

Then disable public sign-ups in the Supabase dashboard (Authentication → Providers → Email). The owner
signs up once, lands on `/welcome`, creates the org, and every later login is created from Setup → Users.
