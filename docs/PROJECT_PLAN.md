# Jyothi Foods — ERP/CRM Master Plan

**Client:** Jyothi Foods — manufacturer & wholesale supplier of traditional sweets and
namkeen, 200+ products, Andhra Pradesh & Telangana.
**Goal:** one system that runs the whole company — accounts, stock, production, vehicles,
staff and customer communication.

**No GST anywhere.** No tax fields, no HSN, no tax invoice, no GST returns. All billing is
plain rate × quantity. (Schema files already stripped.)

---

## 1. Architecture

```
                   ┌──────────────────────────────┐
                   │   Jyothi ERP  (React + Vite) │
   Web browser ───▶│   Owner / Admin / Accountant │
                   │   Store keeper / Production  │
                   └───────────────┬──────────────┘
   Windows .exe ───▶ (same app in Electron shell, license-gated)
                                   │
                   ┌───────────────▼──────────────┐
                   │        SUPABASE              │
                   │  Postgres · RLS · Auth       │
                   │  Edge Functions · Storage    │
                   │  pg_cron (reminders, EOD)    │
                   └───────┬──────────────┬───────┘
                           │              │
              ┌────────────▼───┐   ┌──────▼────────────────┐
              │  Hey Nikki API │   │  Driver mobile (P3)   │
              │  heynikki.in   │   │  Capacitor / Flutter  │
              └────┬──────┬────┘   └───────────────────────┘
                   │      │
        WhatsApp Business │ Telugu voice pipeline
        (Meta-verified)   │ (LiveKit + Sarvam + Gemini)
                   │      │
              ┌────▼──────▼────┐
              │   Customers    │  orders, reminders, catalogs
              └────────────────┘
```

**Principle:** the ERP owns all business data. Hey Nikki is the **communication layer only** —
it sends, listens, transcribes and understands; it never holds stock or ledger state. Every
inbound message or call ends up as a row in `inbound_orders` for a human to confirm.

**Stack:** React 18 + Vite + Tailwind + TanStack Query · Supabase (Postgres, Auth, RLS,
Edge Functions, Storage) · Vercel · Electron for the desktop build · Hey Nikki for WhatsApp
and voice.

---

## 2. Roles & permissions

| Role | Can do |
|---|---|
| **Owner** | Everything, incl. rates, credit limits, license, deletion |
| **Admin** | Everything except license and org settings |
| **Accountant** | Invoices, receipts, payments, returns, customer ledger, all reports. No item rates. |
| **Store keeper** | Items, purchases, van loading/unloading, stock adjustments, stock reports |
| **Production head** | Recipes, batches, production sheet, raw material consumption |
| **Chief** | Only today's open batch — enters actual usage and actual output |
| **Driver** | Own trip only — loaded list, deliveries, collections (Phase 3 mobile) |
| **Sales exec** | Customers, orders, invoices for own route, own collections |

Enforced in Postgres RLS (`db/03_rls.sql`), not just in the UI.

---

## 3. Module 1 — Accounting Management

### 3.1 Customer accounts
Fields: name / company name, mobile 1–3, city/town, address, route, price group,
credit limit, opening balance, WhatsApp opt-in.

- **Single create** — quick form, mobile-1 duplicate check.
- **Bulk import** — CSV/XLSX upload → column mapper → dry-run preview → commit.
  Bad rows download as an error file with the reason per row. Re-import is idempotent
  on mobile number.

### 3.2 Item master (inventory)

Decoded from your price list — the item name itself carries the packing:

> `5/- BOONDI LADDU (12) 48`  →  MRP ₹5/piece · 12 pieces per pack · 48 packs per box

Fields: item code (text — codes like `27 A`, `06: A` exist), **Pack type**
(JAR / PACK / L.B / KG / TRY), item name, **units per box**, **pieces per unit**,
**MRP per piece**, section, unit rate, purchase rate, reorder level, shelf life.

- **Units per box is not fixed at 8.** Your master uses 6, 8, 11, 12, 15, 20, 21, 22, 24,
  25, 30, 32, 40, 48, 50 and 60. It's read per item from the price list `BOX` column
  (`N x 1`). The doc's "jar × 8" is just the most common case, not the rule.
- Box rate is **never typed** — computed live as `unit rate × units per box`.
- Every quantity field in the system is a number + unit dropdown; conversion is automatic.
- Per-customer / per-group rate overrides, so rate differences are priced correctly at
  billing time instead of being adjusted afterwards.

**Sections.** Your stock report groups items under 15 mestri sections —
S-1 CHINNA MASTRY, S-2 KRISHNA MESTRY, S-3 RAVVA LADDU, S-4 TUN TUN (BURFI),
S-5 PAPIDI RAKALU, S-6 NAGA RAJU MESTRY, S-7 CHIKKI RAKALU (SUNIL), S-8 TIPU (CHAKRALU),
S-9 TIPU (KARA RAKALU), S-10 RAMA KRISHNA MESTRI, S-11 GIRI GARU (SUNNUNDA),
S-13 MAIDA RAKALU, OTHERS (UNDALU), OTHERS (PALA KOVA), R.K.BAKERY.
Each item belongs to a section, each section has a mestri. This one link makes the stock
report group correctly **and** ties production output and labour back to the right mestri —
which is what the "Mestry" column in your production sheet is really asking for.

### 3.3 Purchase
Supplier, bill no, date, godown, line items (qty + unit + rate), other charges, total,
paid amount. Posts inward stock on save.

### 3.4 Sale / Invoice — matching your quotation exactly

Header: customer (name + town), invoice date, invoice no, transport name, L.R. no,
L.R. date, freight.

Lines, in your column order:

| S.No | CODE | Item Name | Jars | Boxes | Qty | Rate | Total |
|---|---|---|---|---|---|---|---|
| 1 | 8 | 5/- HT. MYSOOR PAK(12) 32 | 32.00 | 2.00 | 64.00 | 42.00 | 2,688.00 |

**The operator types only CODE, Boxes and Rate.** Jars pulls from the item master,
`Qty = Jars × Boxes`, `Total = Qty × Rate`, rate defaults to the customer's effective rate.
Footer carries total boxes and total qty, then Net Amount and amount in words.

Printed terms, stored per org and editable: damage/breakage **50% recovery**,
interest **24% p.a.** from bill date if unpaid within **15 days**, **Guntur** jurisdiction.

Flow: `draft → confirmed → dispatched → delivered`. Stock leaves only on confirm.

Flow: `draft → confirmed → dispatched → delivered`. Stock leaves only on confirm.
**Vehicle is assigned after the invoice is created**, exactly as specified.

### 3.5 Returns — three kinds, deliberately separated

| Kind | Money credit | Stock effect |
|---|---|---|
| Fresh return | Yes | Comes back as saleable stock |
| Damage / breakage return (**BRK**) | **50% of value** — per your printed terms | Written off, not saleable |
| Rate difference | Yes | **No stock movement at all** |

This is why the register's "return in boxes" column can never be one number.

### 3.6 Receipts & Payments register
Modes: **Cash · Bank · BSR · BRK · UPI · Cheque · Adjustment.**
Receipts allocate against invoices FIFO, or to a specific invoice.

Report output — your exact register:
`S.No · Name · Town · Total Outstanding · Cash · Bank · BSR · BRK · Fresh Return ·
Rate Difference · Return · Remaining Outstanding`

Payments side covers suppliers, staff wages and expense heads.

### 3.7 Closing stock
End-of-day per item: opening, inward, outward, closing — filterable by date and by
location (each godown and each van separately).

---

## 4. Module 2 — Stock / Inventory

- Single ledger (`stock_ledger`); every movement is an immutable row. No screen ever
  writes a stock number directly. This is what makes back-dated entries and audits reconcile.
- Live stock per item **per location**. A vehicle is a stock location, so van stock is
  real stock, not a side sheet.
- **Closing stock report reproduces STOCK_REPORT.xlsx**: grouped by mestri section with
  sub-totals, columns `Item Code · Pack · Group / Item Name · Opening · Purchase · Sales ·
  Closing`, quantities in **boxes**. Negative closing is shown and flagged rather than
  hidden — your current sheet has 7 negative rows, which is exactly the kind of thing the
  ledger will stop happening silently.
- Movement types: opening, purchase, purchase return, production in, production consume,
  sale, sale return, van load, van unload, transfer, damage, adjustment.
- Low-stock flag on the dashboard, and it's the trigger for the "new stock available"
  broadcast in Module 4.

---

## 5. Module 3 — Integrations (Hey Nikki)

`heynikki.in` is the integration layer for both WhatsApp and voice. The ERP talks to it
over HTTPS with a per-org API key; Hey Nikki calls back into a Supabase Edge Function.

### 5.1 Contract

| Direction | Endpoint | Purpose |
|---|---|---|
| ERP → Nikki | `POST /v1/wa/send` | one templated message to one customer |
| ERP → Nikki | `POST /v1/wa/broadcast` | segment broadcast (new stock, catalog) |
| ERP → Nikki | `POST /v1/wa/media` | push catalog PDF |
| ERP → Nikki | `POST /v1/voice/campaign` | outbound reminder calls (Phase 3) |
| Nikki → ERP | `POST /functions/v1/nikki-inbound` | inbound message or call transcript |
| Nikki → ERP | `POST /functions/v1/nikki-status` | sent / delivered / read / failed |

Customers are matched across both systems **by mobile number**, so no separate CRM sync.

### 5.2 WhatsApp ordering
1. Customer sends an order in Telugu or English, free-form or voice note.
2. Hey Nikki transcribes (Sarvam) and passes it to Gemini with the **live item catalog
   injected as context** — item codes, names, common Telugu names, valid units.
3. Gemini returns strict JSON: `[{item_code, qty, uom, confidence}]`.
4. ERP writes it to `inbound_orders` with the raw text kept alongside.
5. Operator sees "Pending Orders" on the dashboard, reviews the parsed lines, edits if
   needed, clicks **Convert to Invoice**. Low-confidence lines are highlighted.
6. Confirmation goes back to the customer automatically.

**Nothing auto-invoices.** Parsing is assistive; a human always confirms. That's the only
safe design when the downstream effect is stock and money.

### 5.3 Order by call
The existing Telugu voice pipeline (LiveKit + Sarvam Saaras STT + Gemini + Sarvam Bulbul TTS)
takes the call on a DID, runs an order-taking conversation in Telugu, reads the order back
for confirmation, then posts to the same `inbound_orders` table with `source='call'` and the
recording URL. From there it's the identical operator flow — one queue for calls and WhatsApp.

### 5.4 Everything integrated to the dashboard
Because every module writes to the same three tables (`stock_ledger`, `invoices`, `receipts`),
the dashboard and reports are integrated by construction — there is no sync job to break.

---

## 6. Module 4 — Reminders, Messages & Catalogs

- **Payment reminders** — rules on minimum outstanding + days overdue, running on `pg_cron`
  (default 10:00 IST). Recipients resolved live from outstanding, sent via Hey Nikki,
  every send logged with delivery status. Escalation ladder: gentle → firm → call.
- **New stock available** — fires when production or purchase brings an item back above
  threshold; targets customers who bought that item in the last N days, not the whole list.
- **Catalog sharing** — catalog PDF in Supabase Storage, pushed to a segment (route, town,
  or last-purchase window) on demand or on a schedule.
- **Transactional** — invoice copy on dispatch, delivery confirmation, receipt acknowledgement.
- Templates in **Telugu and English**, per-customer language preference.
- Opt-out honoured per customer; every message logged for audit.

---

## 7. Module 5 — Production & Management

**Setup (once per item):** recipe = ingredient list with **quantity per plate**, plus
**pieces per plate**. Conversion set at product creation: `1 box = 8 jars`, `1 jar = 38 pieces`
— editable per item, since not every product is 8/38.

**Morning:** production head opens a batch for an item and enters number of plates.
System explodes the recipe and pre-fills the sheet with expected usage, and computes
expected output: `plates × pieces per plate → jars → boxes`.

**Evening:** chief enters actual ingredient usage and actual boxes produced.

**The sheet** — headed by item name, exactly your columns:

`Ingredients · Quantity · No of Plates · Total Usage per Plate · Total Used by Chief ·
Difference · No of Workers · Mestry · Labour`

plus the output comparison **Expected Boxes vs Actual Boxes** and the variance.

**On close:** raw material is consumed from stock, finished goods are added, the batch is
costed (ingredient cost + labour), and yield per plate is recorded so the formula can be
tuned from real data over time.

Variance report: by item, by chief, by week — this is what actually catches leakage.

---

## 8. Module 6 — Vehicle Management

- **Create vehicle:** vehicle number, owner name, driver, route plan, capacity.
  Creates a matching stock location automatically.
- **Trip:** date, vehicle, route, driver, opening/closing km, expenses, status
  (`planned → loaded → dispatched → settled`).
- **Van loading:** stock moves godown → van as a real transfer. Loading sheet prints.
- **Assign vehicle after invoice creation**, per the doc.
- **Day-end settlement:** loaded vs sold vs returned vs cash collected. Any gap is visible
  the same evening, not at month end.
- Route-wise sales and collection reporting.

---

## 9. Reports

**Accounts** — Receipts & Payments register · Customer ledger · Outstanding ageing (0/15/30/60+)
· Collection summary by mode · Route-wise collection · Payments & expenses
**Stock** — Closing stock (date + location) · Stock movement ledger · Low stock ·
Item-wise sales · Damage & breakage
**Production** — Daily production sheet · Ingredient variance · Yield per plate ·
Raw material consumption · Labour cost per batch
**Vehicle** — Trip settlement · Route profitability · Vehicle-wise dispatch
**Sales** — Daily/monthly sales · Customer-wise · Town-wise · Salesman-wise

All exportable to Excel and PDF, print-friendly A4.

---

## 10. Desktop build & licensing

- Electron shell wrapping the same React app, packaged as a signed Windows `.exe` installer.
- **License key activation** on first launch — key validated against `orgs.license_key`
  and `license_valid_till`, re-checked on a schedule.
- If the license lapses or is revoked, the app drops to **read-only** rather than locking the
  client out of their own data — they can still view and export, but not create documents.
  (Cleaner commercially and avoids a data-hostage dispute.)
- Offline: read cache + queued writes, syncing when the connection returns.

---

## 11. Delivery phases

**Phase 1 — Core ERP (web)**
Masters (customers incl. bulk import, items, routes, vehicles, staff) · Purchase ·
Sales invoice · Returns (all three kinds) · Receipts & payments register · Stock ledger +
closing stock · Van loading + vehicle assignment + trip settlement · Production batch &
sheet · Dashboard · Core reports · Roles + RLS.

**Phase 2 — Hey Nikki integration + desktop**
WhatsApp templates and delivery logging · Payment reminder engine · New-stock broadcast ·
Catalog sharing · Inbound WhatsApp order capture and operator confirm queue ·
Electron `.exe` with license activation · Remaining reports.

**Phase 3 — Voice & mobile**
Telugu order-taking calls on the Hey Nikki pipeline · Driver mobile app (van sales,
on-the-spot receipts, delivery proof) · Route profitability · Salesman incentives ·
Batch/expiry tracking · Outbound reminder calls.

---

## 12. Still needed from the client

Three files referenced in the requirements doc weren't in the upload:

1. `jyothi foods quotation.jpg` — to match the quotation/invoice print layout.
2. `stock report.xlsx` — to match the stock report column-for-column.
3. Receipts & payments image/PDF — to confirm the register layout.

Questions to close before Phase 1 build starts:

- **BSR and BRK** — are these collection modes, or deductions (breakage/damage) that reduce
  the bill? Currently modelled as collection modes; if BRK is breakage it moves to the
  returns side. One-line change either way.
- The register had a **GST column** — since we're dropping GST entirely, confirm that column
  can go, or tell me what it actually held so I can name it correctly.
- Purchase — raw materials only, or also finished goods bought in for resale?
- How many godowns, and how many vehicles at present?
- Roughly how many invoices per day, so I can size the dashboard and reports properly.
- Number of ERP users, and which roles.
