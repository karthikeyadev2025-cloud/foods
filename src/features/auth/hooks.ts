import type { Session } from '@supabase/supabase-js';
import { useQuery } from '@tanstack/react-query';
import { createContext, useContext, useMemo } from 'react';
import { getLicenseStatus, type LicenseStatus } from '@/features/license/api';
import { moduleFeature, planLabel, type FeatureKey, type ModuleKey, type PlanKey } from '@/lib/permissions';
import { getMe, getRolePermissions, type Me } from './api';

export interface SessionState {
  session: Session | null;
  /** True until the first getSession() resolves. */
  loading: boolean;
}

export const SessionContext = createContext<SessionState | null>(null);

export function useSession(): SessionState {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error('useSession must be used inside <AuthProvider>');
  return ctx;
}

export const meQueryKey = (uid: string | undefined) => ['me', uid] as const;

/** The staff row + org for the signed-in user. `data === null` means signed in but no org yet. */
export function useMe() {
  const { session } = useSession();
  const uid = session?.user.id;
  return useQuery({
    queryKey: meQueryKey(uid),
    queryFn: getMe,
    enabled: Boolean(uid),
    staleTime: 5 * 60_000,
  });
}

/**
 * The licence state (db/18_licensing.sql). Checked on start, on focus and every half
 * hour; the last answer is kept in the persisted cache so it survives going offline.
 */
export function useLicense() {
  const me = useMe();
  const orgId = me.data?.org_id ?? null;
  return useQuery<LicenseStatus>({
    queryKey: ['license', orgId],
    queryFn: getLicenseStatus,
    enabled: Boolean(orgId),
    staleTime: 5 * 60_000,
    refetchInterval: 30 * 60_000,
    refetchOnWindowFocus: true,
    retry: 2,
  });
}

export interface Permissions {
  isOwner: boolean;
  canView: (module: ModuleKey) => boolean;
  canEdit: (module: ModuleKey) => boolean;
  canDelete: (module: ModuleKey) => boolean;
  /** Is this feature part of the org's licence plan (db/21_plans.sql)? */
  has: (feature: FeatureKey) => boolean;
  plan: PlanKey;
  planName: string;
  /** The licence has lapsed: everything can be viewed and exported, nothing created (T11.2). */
  readOnly: boolean;
  /** True while the role's rows are still loading; callers should not show or hide on it. */
  loading: boolean;
}

/**
 * Mirrors db/06_setup.sql `can_view` / `can_edit` / `can_delete` for the UI.
 * RLS is the boundary; this only decides what to draw. A lapsed licence turns
 * every edit right off here (the DB blocks document creation on its own).
 */
export function usePermissions(): Permissions {
  const me = useMe();
  const license = useLicense();
  const role = me.data?.role ?? null;
  const orgId = me.data?.org_id ?? null;
  const perms = useQuery({
    queryKey: ['permissions', orgId, role],
    queryFn: () => getRolePermissions(role),
    enabled: Boolean(orgId && role && role !== 'owner'),
    staleTime: 5 * 60_000,
  });
  const readOnly = license.data?.read_only ?? false;
  const plan = (license.data?.plan ?? 'full') as PlanKey;
  // Until the licence answers, assume open rather than flashing "locked" on every screen —
  // the database refuses a locked feature either way.
  const features = license.data?.features ?? null;

  return useMemo(() => {
    const isOwner = role === 'owner';
    const rows = perms.data ?? [];
    const find = (m: ModuleKey) => rows.find((r) => r.module === m);
    const has = (f: FeatureKey) => features === null || features.includes(f);
    return {
      isOwner,
      canView: (m) => has(moduleFeature(m)) && (isOwner || Boolean(find(m)?.can_view)),
      canEdit: (m) => !readOnly && has(moduleFeature(m)) && (isOwner || Boolean(find(m)?.can_edit)),
      canDelete: (m) => !readOnly && has(moduleFeature(m)) && (isOwner || Boolean(find(m)?.can_delete)),
      has,
      plan,
      planName: planLabel(plan),
      readOnly,
      loading: me.isLoading || (!isOwner && perms.isLoading),
    };
  }, [role, perms.data, perms.isLoading, me.isLoading, readOnly, plan, features]);
}

export type { Me };
