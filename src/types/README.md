# Generated types

`supabase.ts` is generated, never hand-written:

```bash
npm run gen:types     # supabase gen types typescript --linked > src/types/supabase.ts
```

It is gitignored. Until a Supabase project is linked (T0.2), copy `supabase.stub.ts`
over it so the scaffold type-checks:

```bash
cp src/types/supabase.stub.ts src/types/supabase.ts
```
