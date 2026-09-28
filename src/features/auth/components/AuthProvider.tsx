import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { getSession, onAuthStateChange } from '../api';
import { SessionContext, type SessionState } from '../hooks';
import { isDifferentUser } from '../session';

/** Holds the Supabase session and drops cached per-user data when the USER changes. */
export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<SessionState>({ session: null, loading: true });
  const queryClient = useQueryClient();
  // Who the cached data belongs to. A ref, not state: the auth callback is
  // registered once and must read the current value, not the one captured when
  // the effect ran.
  const uid = useRef<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    getSession()
      .then((session) => {
        if (cancelled) return;
        uid.current = session?.user.id ?? null;
        setState({ session, loading: false });
      })
      .catch(() => {
        if (!cancelled) setState({ session: null, loading: false });
      });
    const unsubscribe = onAuthStateChange((session) => {
      const next = session?.user.id ?? null;
      setState({ session, loading: false });
      // Only when it is somebody else. Supabase refreshes the token whenever the
      // tab regains focus, and purging on that unmounted every open screen —
      // see src/features/auth/session.ts.
      if (isDifferentUser(uid.current, next)) {
        queryClient.removeQueries({ queryKey: ['me'] });
        queryClient.removeQueries({ queryKey: ['permissions'] });
        queryClient.removeQueries({ queryKey: ['setup'] });
      }
      uid.current = next;
    });
    return () => {
      cancelled = true;
      unsubscribe();
    };
  }, [queryClient]);

  return <SessionContext.Provider value={state}>{children}</SessionContext.Provider>;
}
