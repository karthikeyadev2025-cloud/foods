import { useMutation } from '@tanstack/react-query';
import { Boxes, LogOut, MapPin, Monitor, Send, Truck } from 'lucide-react';
import { Link, NavLink, Outlet, useNavigate } from 'react-router-dom';
import { ConnectionBar, LicenceBar } from '@/app/layout/AppShell';
import { signOut } from '@/features/auth/api';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { useOutbox } from '@/hooks/use-offline';
import { toastError } from '@/hooks/use-toast';
import { cn } from '@/lib/utils';

const TABS = [
  { to: '/m', label: 'Trip', icon: Truck, end: true },
  { to: '/m/stops', label: 'Stops', icon: MapPin, end: false },
  { to: '/m/stock', label: 'Van', icon: Boxes, end: false },
  { to: '/m/outbox', label: 'Outbox', icon: Send, end: false },
];

/**
 * The phone chrome: a short top bar, the page, and four tabs at the bottom. Sized
 * for one hand on a 360px screen; the same routes work on a desktop browser too.
 */
export function MobileShell() {
  const me = useMe();
  const perms = usePermissions();
  const navigate = useNavigate();
  const outbox = useOutbox();
  const logout = useMutation({
    mutationFn: signOut,
    onSuccess: () => navigate('/login', { replace: true }),
    onError: (err) => toastError(err, 'Could not sign out'),
  });
  const isDriver = me.data?.role === 'driver';

  return (
    <div className="mx-auto flex h-screen max-w-md flex-col bg-background">
      <header className="flex h-12 shrink-0 items-center justify-between border-b bg-card px-3">
        <div className="min-w-0">
          <div className="truncate text-sm font-bold text-primary">{me.data?.org_name ?? 'JYOTHI FOODS'}</div>
          <div className="truncate text-xs text-muted-foreground">{me.data?.full_name}</div>
        </div>
        <div className="flex items-center gap-1">
          {!isDriver && (
            <Link to="/" className="rounded-md p-2 text-muted-foreground hover:bg-accent" aria-label="Desktop site" title="Desktop site">
              <Monitor className="h-4 w-4" />
            </Link>
          )}
          <button type="button" className="rounded-md p-2 text-muted-foreground hover:bg-accent" aria-label="Sign out" onClick={() => logout.mutate()} disabled={logout.isPending}>
            <LogOut className="h-4 w-4" />
          </button>
        </div>
      </header>
      <ConnectionBar outboxTo="/m/outbox" />
      <LicenceBar canOpenSetup={perms.canView('setup')} />
      <main className="min-w-0 flex-1 overflow-y-auto p-3 pb-4">
        <Outlet />
      </main>
      <nav className="flex shrink-0 border-t bg-card" aria-label="Phone">
        {TABS.map((t) => (
          <NavLink
            key={t.to}
            to={t.to}
            end={t.end}
            className={({ isActive }) => cn('relative flex flex-1 flex-col items-center gap-0.5 py-2 text-[11px]', isActive ? 'text-primary' : 'text-muted-foreground')}
          >
            <t.icon className="h-5 w-5" aria-hidden />
            {t.label}
            {t.to === '/m/outbox' && outbox.length > 0 && <span className="absolute right-1/4 top-1 rounded-full bg-primary px-1.5 text-[10px] text-primary-foreground">{outbox.length}</span>}
          </NavLink>
        ))}
      </nav>
    </div>
  );
}
