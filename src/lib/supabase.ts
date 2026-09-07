import { createClient, type PostgrestError } from '@supabase/supabase-js';
import type { Database } from '@/types/supabase';

interface RowsResult<R> {
  data: R[] | null;
  error: PostgrestError | null;
}
interface OneResult<R> {
  data: R | null;
  error: PostgrestError | null;
}
interface OkResult {
  error: PostgrestError | null;
}

/** Await a list query; throw its PostgrestError (code included) instead of returning it. */
export async function expectRows<R>(query: PromiseLike<RowsResult<R>>): Promise<R[]> {
  const { data, error } = await query;
  if (error) throw error;
  return data ?? [];
}

/** Await a `.single()` query and require a row. */
export async function expectOne<R>(query: PromiseLike<OneResult<R>>): Promise<R> {
  const { data, error } = await query;
  if (error) throw error;
  if (data === null) throw new Error('Expected a row, got none');
  return data;
}

/** Await a write with no result rows. */
export async function expectOk(query: PromiseLike<OkResult>): Promise<void> {
  const { error } = await query;
  if (error) throw error;
}

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

/** True when both env values are present. The shell renders a config warning otherwise. */
export const isSupabaseConfigured = Boolean(url && anonKey);

/**
 * The single Supabase client. Only `features/<x>/api.ts` files may import this —
 * no `supabase.from()` inside a component, ever (DOMAIN_RULES.md rule 2).
 */
export const supabase = createClient<Database>(
  url || 'http://localhost:54321',
  anonKey || 'missing-anon-key',
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  },
);
