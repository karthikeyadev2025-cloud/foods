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
| T0.5 Importer | ⏳ |

Deploy the `create-user` edge function before adding users from Setup:

```bash
supabase functions deploy create-user
```

Then disable public sign-ups in the Supabase dashboard (Authentication → Providers → Email). The owner
signs up once, lands on `/welcome`, creates the org, and every later login is created from Setup → Users.
