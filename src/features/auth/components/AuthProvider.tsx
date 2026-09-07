import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useState, type ReactNode } from 'react';
import { getSession, onAuthStateChange } from '../api';
import { SessionContext, type SessionState } from '../hooks';

/** Holds the Supabase session and drops any cached per-user data when it changes. */
export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<SessionState>({ session: null, loading: true });
  const queryClient = useQueryClient();

  useEffect(() => {
    let cancelled = false;
    getSession()
      .then((session) => {
        if (!cancelled) setState({ session, loading: false });
      })
      .catch(() => {
        if (!cancelled) setState({ session: null, loading: false });
      });
    const unsubscribe = onAuthStateChange((session) => {
      setState({ session, loading: false });
      // A different user (or none) must never see the previous user's cached data.
      queryClient.removeQueries({ queryKey: ['me'] });
      queryClient.removeQueries({ queryKey: ['permissions'] });
      queryClient.removeQueries({ queryKey: ['setup'] });
    });
    return () => {
      cancelled = true;
      unsubscribe();
    };
  }, [queryClient]);

  return <SessionContext.Provider value={state}>{children}</SessionContext.Provider>;
}
