# DOMAIN_RULES.md — Jyothi Foods ERP

Read this file completely before writing any code. It encodes domain rules that are
not obvious from the code and that have already been decoded from the client's real
files. Getting these wrong produces bugs that look like data-entry mistakes and take
weeks to find.

---

## What this is

A single ERP running a traditional sweets and namkeen manufacturer in Andhra Pradesh /
Telangana. 200+ products, wholesale to shops via van routes. Covers accounting, stock,
production, vehicles, staff and customer messaging.

**Client-facing language is English + Telugu. Item names are transliterated Telugu in caps
(`5/- BOONDI LADDU (12) 48`) — never "clean up", translate, or re-case them.**

---

## Non-negotiable domain rules

These come from the client's actual quotation, price list and stock report. Violating any
of them is a correctness bug, not a style choice.

### 1. NO GST. Anywhere.
No tax fields, no HSN, no tax invoice, no GST returns, no tax columns on any report or
print. If you find yourself adding a `gst_` or `tax_` field, stop — it's wrong.

### 2. `units_per_box` is per item. It is NOT 8.
The master uses 6, 8, 11, 12, 15, 20, 21, 22, 24, 25, 30, 32, 40, 48, 50, 60.
Never hard-code 8 anywhere. Always read `items.units_per_box`.

### 3. Item names encode packing — parse, don't invent
```
5/- BOONDI LADDU (12) 48
│    │                │  └── 48 packs per box   → units_per_box
│    │                └───── 12 pieces per pack → pieces_per_unit
│    └────────────────────── item name
└─────────────────────────── ₹5 MRP per piece   → mrp_per_piece
```

### 4. Invoice line maths (from the real quotation)
```
Qty   = boxes × units_per_box
Total = Qty  × rate
```
- **Rate is per UNIT (jar / pack / L.B), never per box.**
- The operator types only **CODE, Boxes, Rate**. Jars, Qty and Total are all derived
  and must be read-only in the UI.
- Column order on screen and print is fixed:
  `S.No | CODE | Item Name | Jars | Boxes | Qty | Rate | Total`
- Footer shows total boxes and total qty, then Net Amount and amount in words.

### 5. Three kinds of return, never one
| Kind | Money credit | Stock |
|---|---|---|
| `fresh_return` | full | comes back saleable |
| `damage_return` (**BRK** = breakage) | **50% of value** | written off, not saleable |
| `rate_difference` | full | **no stock movement at all** |

50% is `orgs.breakage_recovery_pct`, not a literal.

### 6. Stock is an append-only ledger
`stock_ledger` is the only source of stock truth. **No screen, query or service ever
UPDATEs or DELETEs a stock quantity.** Every movement is a new row. Corrections are
`adjustment` rows. Live stock is always a `SUM()`.

Negative stock is **allowed and flagged**, never blocked or clamped — the client's real
data has 7 negative rows and hiding them destroys the audit trail.

### 7. Items belong to mestri sections
15 sections (S-1 … S-13, plus `OTHERS (UNDALU)`, `OTHERS (PALA KOVA)`, `R.K.BAKERY`).
The stock report **must** group and sub-total by section in `sections.sort_order`.
Production labour ties back to the section's mestri.

### 8. Item codes are TEXT, not integers
Real codes include `27 A`, `06: A`, `01: A`, `83B`, `200A`. Normalise on import
(strip spaces and colons, uppercase) but never cast to int or zero-pad.

### 9. A vehicle is a stock location
Van stock is real stock in `stock_ledger`, not a separate table. Loading a van is a
transfer between two locations.

### 10. One trade name: JYOTHI FOODS
There is no multi-firm dimension and no `firms` table. Every document prints under
**JYOTHI FOODS**. `R.K.BAKERY`, `OTHERS (UNDALU)` and `OTHERS (PALA KOVA)` in the stock
report are production **sections**, not separate businesses — they're already modelled in
`sections`. Don't add a firm concept "for flexibility"; it puts a nullable foreign key on
every document for a distinction the business doesn't make.

### 11. Money posts to the journal, always
Every invoice, purchase, receipt, payment, return and production close writes a balanced
`journal_entries` + `journal_lines` pair. **Never compute "profit" by summing four unrelated
tables** — that's how two reports end up disagreeing and nobody can say which is right.
The trial balance must net to zero for any date range; treat that as a test, not a hope.

### 12. Printed trade terms come from `orgs`
Breakage 50% recovery · interest 24% p.a. · 15 days credit · Guntur jurisdiction.
Editable per org, never hard-coded in a template.

---

## The core principle: masters define, transactions derive

**Every packing number and every price is entered once, on Add Product. Nowhere else.**
No transaction screen ever asks the operator to type a packing figure or a box rate.
If a value can be derived from a master, deriving it is not an optimisation — typing it
by hand is a bug, because two people will eventually type it differently.

Add Product is the only place these are set:

| Field | Set on Add Product | Everything downstream |
|---|---|---|
| `units_per_box` | typed | invoice "Jars" column · stock report box conversion · production output · van loading |
| `pieces_per_unit` | typed | production expected pieces · MRP checks |
| `mrp_per_piece` | typed | print, catalog |
| `unit_rate` | typed | invoice rate default · returns valuation · stock value |
| `box_rate` | **computed, read-only** | `unit_rate × units_per_box` — never stored as input, never typed |
| `pack_type` | typed | stock report "Pack" column, print |
| `section_id` | typed | stock report grouping · production mestri |

What that means on each screen:

- **Invoice** — operator types CODE, Boxes, Rate. Jars comes from the master, Qty is
  `boxes × units_per_box`, Total is `qty × rate`. Three of six columns are read-only.
- **Stock report** — box figures are ledger base-units ÷ `units_per_box`. Never a
  separately maintained box count.
- **Production** — `plates × pieces_per_plate → ÷ pieces_per_unit → ÷ units_per_box`.
  The whole expected-vs-actual chain rides on the master.
- **Van loading, returns, adjustments** — same conversion, same source.

Apply this same discipline everywhere else, not just to products:

| Master | Defines | Derived downstream |
|---|---|---|
| Customer | route, price group, credit limit, opening balance | invoice rate default, ageing, reminder targeting |
| Section | mestri, sort order | stock report grouping and sub-totals, production labour attribution |
| Recipe | qty per plate, pieces per plate | the entire expected column of the production sheet |
| Vehicle | route, driver, stock location | van stock, trip settlement, dispatch |
| Org | breakage %, interest %, credit days, jurisdiction | printed invoice terms, breakage credit maths |

**If a screen asks for a number that already exists on a master, delete the field.**

### Two consequences, handle them deliberately

**1. Transactions snapshot, they don't reference.**
`invoice_items` stores `units_per_box` and `rate` **as at billing time**. A later master
change must never silently re-price or re-quantify a printed invoice. Defaults come from
the master; the saved row is history.

**2. Packing is locked once an item has stock movement.**
Changing `units_per_box` on an item with ledger rows retroactively changes the box figure
of every historical closing-stock report — because stock is held in base units. So:
`units_per_box` becomes read-only after the item's first `stock_ledger` row. To repack,
create a new item code.

The client already works this way. `5/- BOONDI CHIKKI (12)24 NEW` and
`5/- BOONDI CHIKKI (12)32 NEW` are the same sweet at two packings under two codes — that's
why 87 codes in the stock report aren't on the price list. Follow their convention; don't
try to "fix" it with a packing-history table.

---

## Everything is created from the CRM. Nothing is static.

This is a production system the client runs themselves, not a demo seeded by a developer.
**If a value appears on a screen, there is a screen where the client created it.** No
hard-coded dropdown, no enum the client can't extend, no config file only we can edit, no
data that only exists because someone ran a script.

Configurable from Setup — these are **tables, not enums**:

| Table | What the client manages |
|---|---|
| `uoms` | their own units — code, name, and which of four bases it converts on (`box`/`unit`/`piece`/`weight`) |
| `pack_types` | the "Pack" label — JAR, PACK, L.B, KG, TRY, and anything they add |
| `receipt_modes` | Cash, Bank, BSR, BRK, UPI… each flagged collection vs deduction, and whether it needs a reference |
| `expense_heads` | payment/expense categories |
| `sections` | mestri sections, their order on the stock report |
| `item_categories`, `routes`, `stock_locations`, `vehicles`, `staff` | all CRUD |
| `number_series` | per document type: prefix, width, suffix, reset never/yearly/monthly/daily |
| `role_permissions` | module-level view/edit/delete per role |
| `message_templates`, `reminder_rules`, `catalogs` | messaging, editable without a deploy |
| `orgs` | breakage %, interest %, credit days, jurisdiction, license |

Because modes are rows, `receipts_register()` returns `by_mode` as JSON and the UI renders
**one column per active mode**. Add a new head in Setup and the register grows a column —
no migration, no code change. **This is why BSR being undefined doesn't block us.**

Structural enums stay enums, because they change program behaviour rather than labels:
`stock_txn_type`, `return_kind`, `invoice_status`, `trip_status`, `batch_status`,
`staff_role`, `uom_basis`. Adding a value to any of these means writing code, so it isn't
something a user can safely do from a screen.

**Import is a screen, not a script.** `scripts/import_masters.py` was for decoding the
client's spreadsheets during design. In the product, `import_jobs` backs an in-app importer
— upload, map columns, dry-run preview, error rows download, commit — used for items,
customers, opening stock and rate lists. The client updates their own master data.

**First run is a setup wizard, not a seeded database.** Create org → trade terms →
units → pack types → receipt modes → sections and mestris → locations → number series →
first user. Then import or key in items and customers. A fresh deploy with an empty
database must be usable by the client without a developer touching SQL.

---

## Stack

| Layer | Choice | Notes |
|---|---|---|
| Frontend | React 18 + Vite + TypeScript | strict mode on |
| Styling | Tailwind + shadcn/ui | no other UI kit |
| Data | TanStack Query | no Redux, no Zustand for server state |
| Forms | react-hook-form + zod | zod schema is the single source of validation |
| Backend | Supabase — Postgres, Auth, RLS, Edge Functions, Storage | |
| Scheduling | pg_cron | reminders, end-of-day |
| Messaging | Hey Nikki API (`heynikki.in`) | WhatsApp + Telugu voice |
| Deploy | Vercel | |
| Desktop | Electron, license-gated | Phase 2 |

**Money and quantity: `numeric` in Postgres, and `number` in TS only at the edge.**
Never use floats for intermediate money maths. Round only at display and at `amount`.

---

## Repo layout

```
/db                 numbered SQL migrations — run in order, never edit a shipped one
  01_schema.sql      core: masters, stock ledger, sales, production, vehicles
  02_logic.sql       conversion, posting, reports, numbering
  03_rls.sql         row level security
  04_extended.sql    cash/bank, journal, orders, price lists, batches, print, backup
/scripts            one-off importers and data tools (Python)
/seed               generated CSVs from the client's real files
/src
  /app              routes, layout, providers
  /features         one folder per domain: customers, items, purchases, invoices,
                    returns, receipts, stock, production, vehicles, messaging, reports
    /<feature>
      api.ts        all Supabase calls for this feature — nothing else touches the DB
      schema.ts     zod schemas + inferred types
      components/
      routes/
  /components       shared UI only
  /lib              supabase client, formatters, units, money
  /types            generated Supabase types (supabase gen types)
/supabase/functions edge functions: nikki-inbound, nikki-status, run-reminders, eod-close
/docs               PROJECT_PLAN.md, BUILD_TASKS.md
```

---

## Rules for writing code here

1. **One feature folder per domain. No cross-feature imports** except through
   `/components` and `/lib`. If invoices needs customers, it goes through
   `features/customers/api.ts`.
2. **All DB access lives in `api.ts`.** No `supabase.from()` inside a component, ever.
3. **Types are generated, not hand-written.** Run `supabase gen types typescript` after
   any migration and import from `/types`.
4. **Never edit a shipped migration.** Add `04_`, `05_` and so on.
5. **RLS is the security boundary, not the UI.** If a role shouldn't see it, the policy
   must stop it. UI hiding is cosmetic only.
6. **Every list screen**: server-side pagination, search, and an Excel export. 200+ items
   and thousands of invoices — no client-side filtering of full tables.
7. **Every money/qty display** goes through `lib/format.ts`. Indian grouping
   (`34,258.00`), two decimals, `₹` prefix on money only.
8. **Errors surface to the user.** No silent catch. Toast on failure, and log the
   Postgres error code.
9. **No `any`.** No `@ts-ignore`. If types fight you, fix the type.
10. **Write the query first, then the screen.** If a report needs a new SQL function, add
    it as a migration rather than assembling it in JS.

---

## What NOT to do

- Don't add GST, tax, or HSN anything.
- Don't hard-code 8, 38, 50%, 24%, or 15 days.
- Don't UPDATE or DELETE `stock_ledger` or `journal_entries`. Corrections are reversing entries.
- Don't auto-convert a WhatsApp or call order into an invoice. A human confirms. Always.
- Don't block negative stock.
- Don't rename, translate or title-case item names.
- Don't build a generic "settings" god-screen. Settings live with their feature.
- Don't put a packing or box-rate input on any transaction screen. Add Product owns them.
- Don't let `units_per_box` stay editable once an item has stock movement.
- Don't hard-code a dropdown. If it's a list of choices the client owns, it's a table.
- Don't add an enum for anything the client might want to extend.
- Don't require a script, a SQL console, or a redeploy for anything the client does routinely.
- Don't add a new library without a reason that can't be met by the stack above.

---

## Integration boundary — Hey Nikki

The ERP owns all business data. Hey Nikki (`heynikki.in`) is **communication only** —
it sends, listens, transcribes, understands. It never holds stock or ledger state.

| Direction | Endpoint |
|---|---|
| ERP → Nikki | `POST /v1/wa/send`, `/v1/wa/broadcast`, `/v1/wa/media`, `/v1/voice/campaign` |
| Nikki → ERP | `POST /functions/v1/nikki-inbound`, `/functions/v1/nikki-status` |

Customers match across both systems **by mobile number**. Every inbound message or call
lands in `inbound_orders` with `status='new'` for an operator to confirm.

---

## Definition of done, per feature

- [ ] Migration applied, types regenerated
- [ ] RLS policy written and tested from a non-owner role
- [ ] `api.ts` covers create / read / update / list with pagination
- [ ] zod schema validates everything the DB constrains
- [ ] Loading, empty, and error states all render
- [ ] Excel export on any list or report
- [ ] Print layout matches the client's paper form where one exists
- [ ] Works at 1366×768 — the client's shop machines are not big monitors

---

## Open questions — ask, don't guess

1. **BSR** — meaning still unknown. Collection mode or deduction head? Currently a
   receipt mode; may need to move.
2. **Rates** — no rate column in either spreadsheet. Item master cannot go live without
   the current rate list.
3. **87 items** are in the stock report but not the price list (the "NEW" lines and
   suffixed codes). See `seed/unmatched_items.csv` — needs units-per-box and rate.
4. Purchase — raw materials only, or bought-in finished goods too? (R.K.BAKERY items
   look bought in.)
5. Godown count, vehicle count, invoices/day, user count by role.

If a decision is needed and the answer isn't here, **leave a `TODO(client):` comment and
pick the reversible option** rather than inventing a rule.
