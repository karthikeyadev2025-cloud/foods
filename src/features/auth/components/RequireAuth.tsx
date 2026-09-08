import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { Spinner } from '@/components/Spinner';
import { toastError } from '@/hooks/use-toast';
import { useEffect } from 'react';
import { useMe, useSession } from '../hooks';

/**
 * Gate for everything except /login. Not signed in → /login. Signed in with no
 * org yet → /welcome (first-run bootstrap). RLS still guards the data either way.
 */
export function RequireAuth() {
  const { session, loading } = useSession();
  const me = useMe();
  const location = useLocation();

  useEffect(() => {
    if (me.error) toastError(me.error, 'Could not load your profile');
  }, [me.error]);

  if (loading) return <Spinner label="Checking sign-in…" full />;
  if (!session) return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  if (me.isLoading) return <Spinner label="Loading your organisation…" full />;
  if (me.error) return <Navigate to="/login" replace />;
  if (me.data === null && location.pathname !== '/welcome') return <Navigate to="/welcome" replace />;
  if (me.data && location.pathname === '/welcome') return <Navigate to="/" replace />;
  // Drivers live on the phone screens; the desktop shell has nothing for them.
  if (me.data?.role === 'driver' && !location.pathname.startsWith('/m')) return <Navigate to="/m" replace />;
  return <Outlet />;
}
