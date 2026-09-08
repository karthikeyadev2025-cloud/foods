import { useMutation, useQueryClient } from '@tanstack/react-query';
import { AlertTriangle, CloudOff, LogOut, Send } from 'lucide-react';
import { Link, NavLink, Outlet, useNavigate } from 'react-router-dom';
import { NAV } from '@/app/nav';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { signOut } from '@/features/auth/api';
import { useLicense, useMe, usePermissions } from '@/features/auth/hooks';
import { useOnline, useOutbox } from '@/hooks/use-offline';
import { toast, toastError } from '@/hooks/use-toast';
import { dateDMY } from '@/lib/format';
import { roleLabel } from '@/lib/permissions';
import { isSupabaseConfigured, replayOutbox } from '@/lib/supabase';
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
        <ConnectionBar />
        <LicenceBar canOpenSetup={perms.canView('setup')} />

        <main className="min-w-0 flex-1 overflow-y-auto p-4">
          <Outlet />
        </main>
      </div>
    </div>
  );
}

const barClass = (tone: 'amber' | 'red' | 'blue') =>
  cn(
    'no-print flex items-center gap-2 border-b px-4 py-1.5 text-sm',
    tone === 'amber' && 'border-amber-300 bg-amber-50 text-amber-900',
    tone === 'red' && 'border-red-300 bg-red-50 text-red-900',
    tone === 'blue' && 'border-sky-300 bg-sky-50 text-sky-900',
  );

/** Offline notice, and the outbox count while documents wait to be sent. */
function ConnectionBar() {
  const online = useOnline();
  const outbox = useOutbox();
  const qc = useQueryClient();
  const send = useMutation({
    mutationFn: replayOutbox,
    onSuccess: async (r) => {
      await qc.invalidateQueries();
      if (r.sent) toast({ title: `${r.sent} sent from the outbox` });
    },
    onError: (err) => toastError(err, 'Could not send the outbox'),
  });
  if (!online)
    return (
      <div role="status" className={barClass('amber')}>
        <CloudOff className="h-4 w-4 shrink-0" aria-hidden />
        Offline — showing saved data. New documents wait in the{' '}
        <Link to="/outbox" className="underline">
          outbox
        </Link>
        {outbox.length > 0 && ` (${outbox.length})`}.
      </div>
    );
  if (!outbox.length) return null;
  return (
    <div role="status" className={barClass('blue')}>
      <Send className="h-4 w-4 shrink-0" aria-hidden />
      {outbox.length} document{outbox.length === 1 ? '' : 's'} waiting to be sent.
      <Button size="sm" variant="outline" className="h-6" onClick={() => send.mutate()} disabled={send.isPending}>
        {send.isPending ? 'Sending…' : 'Send now'}
      </Button>
      <Link to="/outbox" className="underline">
        View outbox
      </Link>
    </div>
  );
}

/** Trial and licence warnings; red once the app is read-only. */
function LicenceBar({ canOpenSetup }: { canOpenSetup: boolean }) {
  const license = useLicense();
  const s = license.data;
  if (!s) return null;
  let text: string | null = null;
  let tone: 'amber' | 'red' = 'amber';
  if (s.status === 'trial' && s.days_left <= 7) text = `Trial ends ${s.valid_till ? dateDMY(s.valid_till) : 'soon'} (${s.days_left} day${s.days_left === 1 ? '' : 's'} left). Enter the licence key to keep working.`;
  else if (s.status === 'unlicensed') {
    tone = 'red';
    text = 'The trial is over and the app is read-only: screens and exports work, new documents are blocked until a licence key is entered.';
  } else if (s.status === 'grace') text = `The licence expired ${s.valid_till ? dateDMY(s.valid_till) : ''}. Renew within ${s.grace_days} days or the app becomes read-only.`;
  else if (s.status === 'expired') {
    tone = 'red';
    text = 'The licence has expired and the app is read-only: screens and exports work, new documents are blocked until it is renewed.';
  } else if (s.status === 'active' && s.days_left <= 14) text = `Licence expires ${s.valid_till ? dateDMY(s.valid_till) : ''} (${s.days_left} day${s.days_left === 1 ? '' : 's'}).`;
  if (!text) return null;
  return (
    <div role={tone === 'red' ? 'alert' : 'status'} className={barClass(tone)}>
      <AlertTriangle className="h-4 w-4 shrink-0" aria-hidden />
      <span>{text}</span>
      {canOpenSetup ? (
        <Link to="/setup/licence" className="underline">
          Licence
        </Link>
      ) : (
        <span className="text-muted-foreground">Ask the owner.</span>
      )}
    </div>
  );
}
