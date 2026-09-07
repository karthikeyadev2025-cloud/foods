import { useMutation } from '@tanstack/react-query';
import { AlertTriangle, LogOut } from 'lucide-react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import { NAV } from '@/app/nav';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { signOut } from '@/features/auth/api';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { toastError } from '@/hooks/use-toast';
import { roleLabel } from '@/lib/permissions';
import { isSupabaseConfigured } from '@/lib/supabase';
import { cn } from '@/lib/utils';

/**
 * The application chrome: fixed sidebar, top bar, scrolling content.
 * Sized for 1366×768 — the sidebar is 13rem and the content pane never
 * assumes more than ~1100px of width.
 *
 * The sidebar only lists modules the role can view. That is cosmetic; RLS
 * returns nothing for the rest even if the URL is typed by hand.
 */
export function AppShell() {
  const me = useMe();
  const perms = usePermissions();
  const navigate = useNavigate();
  const logout = useMutation({
    mutationFn: signOut,
    onSuccess: () => navigate('/login', { replace: true }),
    onError: (err) => toastError(err, 'Could not sign out'),
  });

  const groups = NAV.map((g) => ({ ...g, items: g.items.filter((i) => perms.canView(i.module)) })).filter(
    (g) => g.items.length > 0,
  );

  return (
    <div className="flex h-screen overflow-hidden">
      <aside className="no-print flex w-52 shrink-0 flex-col border-r bg-card">
        <div className="flex h-12 items-center border-b px-4">
          <span className="truncate text-sm font-bold tracking-wide text-primary" title={me.data?.org_name ?? ''}>
            {me.data?.org_name ?? 'JYOTHI FOODS'}
          </span>
        </div>
        <nav className="flex-1 overflow-y-auto py-2" aria-label="Main">
          {groups.map((group) => (
            <div key={group.label} className="mb-2">
              <div className="px-4 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
                {group.label}
              </div>
              {group.items.map((item) => (
                <NavLink
                  key={item.to}
                  to={item.to}
                  end={item.to === '/'}
                  className={({ isActive }) =>
                    cn(
                      'mx-2 flex items-center gap-2 rounded-md px-2 py-1.5 text-sm text-foreground/80 hover:bg-accent hover:text-accent-foreground',
                      isActive && 'bg-primary/10 font-medium text-primary',
                    )
                  }
                >
                  <item.icon className="h-4 w-4" aria-hidden />
                  {item.label}
                </NavLink>
              ))}
            </div>
          ))}
        </nav>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="no-print flex h-12 shrink-0 items-center justify-between border-b bg-card px-4">
          <div className="text-sm text-muted-foreground">ERP</div>
          <div className="flex items-center gap-3 text-sm">
            {me.data && (
              <>
                <span className="font-medium">{me.data.full_name}</span>
                <Badge variant="secondary">{roleLabel(me.data.role)}</Badge>
              </>
            )}
            <Button variant="ghost" size="sm" onClick={() => logout.mutate()} disabled={logout.isPending} aria-label="Sign out">
              <LogOut /> Sign out
            </Button>
          </div>
        </header>

        {!isSupabaseConfigured && (
          <div
            role="alert"
            className="no-print flex items-center gap-2 border-b border-amber-300 bg-amber-50 px-4 py-2 text-sm text-amber-900"
          >
            <AlertTriangle className="h-4 w-4 shrink-0" aria-hidden />
            Supabase is not configured. Copy <code className="mx-1 rounded bg-amber-100 px-1">.env.example</code> to
            <code className="mx-1 rounded bg-amber-100 px-1">.env</code> and fill in the project URL and anon key.
          </div>
        )}

        <main className="min-w-0 flex-1 overflow-y-auto p-4">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
