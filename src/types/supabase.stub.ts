// PLACEHOLDER — regenerate with `npm run gen:types` once the migrations are applied
// (T0.2). This file is gitignored; the stub exists only so the scaffold type-checks
// before a database is linked.
//
// Do not hand-edit table types here. Types are generated, not written (DOMAIN_RULES.md rule 3).

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export interface Database {
  public: {
    Tables: Record<string, never>;
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
}
