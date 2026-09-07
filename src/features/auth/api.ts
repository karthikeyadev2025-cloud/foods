import type { Session } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

export type Me = Database['public']['Views']['v_me']['Row'];
export type RolePermission = Database['public']['Tables']['role_permissions']['Row'];

export async function signIn(email: string, password: string): Promise<void> {
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
}

export async function signOut(): Promise<void> {
  resetOrgCache();
  const { error } = await supabase.auth.signOut();
  if (error) throw error;
}

export async function getSession(): Promise<Session | null> {
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  return data.session;
}

export function onAuthStateChange(cb: (session: Session | null) => void): () => void {
  const { data } = supabase.auth.onAuthStateChange((_event, session) => {
    resetOrgCache();
    cb(session);
  });
  return () => data.subscription.unsubscribe();
}

/** The signed-in user's staff row joined to their org, or null if they have no org yet. */
export async function getMe(): Promise<Me | null> {
  const { data, error } = await supabase.from('v_me').select('*').maybeSingle();
  if (error) throw error;
  return data;
}

let cachedOrgId: string | null = null;

/**
 * The caller's org id, cached per sign-in. Other features' api.ts files use it to
 * stamp `org_id` on inserts so no screen has to know it; RLS rejects anything else.
 */
export async function currentOrgId(): Promise<string> {
  if (cachedOrgId) return cachedOrgId;
  const me = await getMe();
  if (!me?.org_id) throw new Error('This login is not attached to an organisation yet');
  cachedOrgId = me.org_id;
  return cachedOrgId;
}

export function resetOrgCache(): void {
  cachedOrgId = null;
}

export async function getRolePermissions(role: Me['role']): Promise<RolePermission[]> {
  if (!role) return [];
  const { data, error } = await supabase.from('role_permissions').select('*').eq('role', role);
  if (error) throw error;
  return data;
}

export interface BootstrapInput {
  orgName: string;
  fullName: string;
  phone?: string | undefined;
}

/** First run: create the org and make the caller its owner. Server-side RPC, see db/06_setup.sql. */
export async function bootstrapOrg(input: BootstrapInput): Promise<string> {
  const { data, error } = await supabase.rpc('bootstrap_org', {
    p_org_name: input.orgName,
    p_full_name: input.fullName,
    p_phone: input.phone ?? undefined,
  });
  if (error) throw error;
  resetOrgCache();
  return data;
}
