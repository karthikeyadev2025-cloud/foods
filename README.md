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

Apply migrations in order, then generate types:

```bash
psql "$DATABASE_URL" -f db/01_schema.sql
psql "$DATABASE_URL" -f db/02_logic.sql
psql "$DATABASE_URL" -f db/03_rls.sql
psql "$DATABASE_URL" -f db/04_extended.sql
npm run gen:types             # supabase gen types typescript --linked > src/types/supabase.ts
```

Until a Supabase project is linked, the scaffold type-checks against a stub:

```bash
cp src/types/supabase.stub.ts src/types/supabase.ts
```

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
| T0.2 Database | ⏳ needs a Supabase project |
| T0.3 Auth + shell | ⏳ |
