import type { Session } from '@supabase/supabase-js';
import { useQuery } from '@tanstack/react-query';
import { createContext, useContext, useMemo } from 'react';
import type { ModuleKey } from '@/lib/permissions';
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

export interface Permissions {
  isOwner: boolean;
  canView: (module: ModuleKey) => boolean;
  canEdit: (module: ModuleKey) => boolean;
  canDelete: (module: ModuleKey) => boolean;
  /** True while the role's rows are still loading; callers should not show or hide on it. */
  loading: boolean;
}

/**
 * Mirrors db/06_setup.sql `can_view` / `can_edit` / `can_delete` for the UI.
 * RLS is the boundary; this only decides what to draw.
 */
export function usePermissions(): Permissions {
  const me = useMe();
  const role = me.data?.role ?? null;
  const orgId = me.data?.org_id ?? null;
  const perms = useQuery({
    queryKey: ['permissions', orgId, role],
    queryFn: () => getRolePermissions(role),
    enabled: Boolean(orgId && role && role !== 'owner'),
    staleTime: 5 * 60_000,
  });

  return useMemo(() => {
    const isOwner = role === 'owner';
    const rows = perms.data ?? [];
    const find = (m: ModuleKey) => rows.find((r) => r.module === m);
    return {
      isOwner,
      canView: (m) => isOwner || Boolean(find(m)?.can_view),
      canEdit: (m) => isOwner || Boolean(find(m)?.can_edit),
      canDelete: (m) => isOwner || Boolean(find(m)?.can_delete),
      loading: me.isLoading || (!isOwner && perms.isLoading),
    };
  }, [role, perms.data, perms.isLoading, me.isLoading]);
}

export type { Me };
