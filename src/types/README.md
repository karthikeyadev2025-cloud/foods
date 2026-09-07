# Generated types

`supabase.ts` is generated, never hand-written (DOMAIN_RULES.md rule 3). It is committed so
every checkout type-checks without a database, and **must be regenerated after every
migration**:

```bash
DATABASE_URL=postgresql://... npm run gen:types
```

`scripts/gen-types.mjs` runs the same generator as the Supabase CLI
(`@supabase/postgres-meta` + `@supabase/postgrest-typegen`) but needs no Docker, so it
works against a local Postgres or a Supabase project's direct connection string. The
CLI form is equivalent if you prefer it:

```bash
supabase gen types typescript --db-url "$DATABASE_URL" --schema public > src/types/supabase.ts
```
