import { createClient } from '@supabase/supabase-js';
import type { Database } from '@/types/supabase';

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
