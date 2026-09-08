import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Link2, Link2Off, RefreshCw, Save, Trash2 } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe } from '@/features/auth/hooks';
import {
  forgetStaffAttendance, getPunchlySettings, linkPunchlyStaff, punchlyRoster, savePunchlySettings, syncPunchlyNow,
  type PunchlyPatch, type SyncResult,
} from '@/features/attendance/api';
import { toast, toastError } from '@/hooks/use-toast';
import { dateTimeDMY } from '@/lib/format';
import { cn } from '@/lib/utils';

const SETTINGS_KEY = ['punchly', 'settings'] as const;
const ROSTER_KEY = ['punchly', 'roster'] as const;

/**
 * Punchly: the phone app the staff punch on. The ERP reads it — there is nothing to
 * write back and no webhook, so the punches are fetched twice an hour and folded into
 * the attendance register. The key is held server-side and never comes back to this
 * screen; only its last four characters do.
 */
export function PunchlyPanel({ compact }: { compact?: boolean }) {
  const me = useMe();
  const qc = useQueryClient();
  const settings = useQuery({ queryKey: SETTINGS_KEY, queryFn: getPunchlySettings });
  const canEdit = me.data?.role === 'owner' || me.data?.role === 'admin';

  const [key, setKey] = useState('');
  const [form, setForm] = useState<PunchlyPatch>({});
  useEffect(() => {
    if (settings.data) setForm({});
  }, [settings.data]);
  const value = <K extends keyof PunchlyPatch>(k: K): PunchlyPatch[K] =>
    (form[k] ?? (settings.data as Record<string, unknown> | undefined)?.[k]) as PunchlyPatch[K];
  const set = <K extends keyof PunchlyPatch>(k: K, v: PunchlyPatch[K]) => setForm((f) => ({ ...f, [k]: v }));

  const save = useMutation({
    mutationFn: () => savePunchlySettings({ ...form, ...(key.trim() ? { api_key: key.trim() } : {}) }),
    onSuccess: (s) => {
      qc.setQueryData(SETTINGS_KEY, s);
      setKey('');
      setForm({});
      toast({ title: 'Punchly settings saved' });
    },
    onError: (e) => toastError(e, 'Could not save'),
  });

  const [lastSync, setLastSync] = useState<SyncResult | null>(null);
  const sync = useMutation({
    mutationFn: syncPunchlyNow,
    onSuccess: async (rows) => {
      setLastSync(rows[0] ?? null);
      await qc.invalidateQueries({ queryKey: SETTINGS_KEY });
      await qc.invalidateQueries({ queryKey: ROSTER_KEY });
      await qc.invalidateQueries({ queryKey: ['attendance'] });
      const failed = rows.find((r) => r.error);
      if (failed) return toast({ title: 'Punchly could not be read', description: failed.error, variant: 'destructive' });
      const written = rows.reduce((s, r) => s + r.written, 0);
      toast({ title: written ? `${written} day${written === 1 ? '' : 's'} updated` : 'Nothing new to bring in' });
    },
    onError: (e) => toastError(e, 'Could not reach Punchly'),
  });

  if (settings.isLoading) return <Spinner />;
  if (settings.error) return <p role="alert" className="text-sm text-destructive">{settings.error.message}</p>;
  const s = settings.data;

  return (
    <section className="space-y-4">
      <div>
        <h2 className={compact ? 'text-base font-semibold' : 'text-lg font-semibold'}>Attendance (Punchly)</h2>
        <p className="max-w-2xl text-sm text-muted-foreground">
          Punchly is where the staff punch in and out on their phones. The ERP reads it every half hour and turns the punches
          into one row per person per day under Attendance — first check-in, last check-out, hours, overtime and the day's wage.
          Nothing is ever written back to Punchly.
        </p>
      </div>

      <form
        className="grid max-w-3xl gap-3 rounded-md border p-4 sm:grid-cols-2"
        onSubmit={(ev) => { ev.preventDefault(); save.mutate(); }}
      >
        <Field
          label="API key"
          htmlFor="pl-key"
          className="sm:col-span-2"
          help={
            s?.has_api_key
              ? `A key ending ${s.api_key_hint?.slice(-4)} is saved. Type a new one to replace it; it is never shown again.`
              : 'From Punchly → Settings → API keys. It needs the attendance:read and staff:read scopes. The key is kept on the server and never reaches this browser.'
          }
        >
          <Input id="pl-key" value={key} onChange={(e) => setKey(e.target.value)} placeholder="pk_live_…" autoComplete="off" className="font-mono" disabled={!canEdit} />
        </Field>

        <Field label="API address" htmlFor="pl-url">
          <Input id="pl-url" value={String(value('api_url') ?? '')} onChange={(e) => set('api_url', e.target.value)} disabled={!canEdit} />
        </Field>
        <Field label="Load history from" htmlFor="pl-backfill" help="Set a date once to pull the past in; it clears itself when it catches up.">
          <Input id="pl-backfill" type="date" value={String(value('backfill_from') ?? '')} onChange={(e) => set('backfill_from', e.target.value)} disabled={!canEdit} />
        </Field>

        <Field label="A full day is" htmlFor="pl-full" help="Hours. At or above this, the day counts as present.">
          <Input id="pl-full" type="number" step="0.5" min="0.5" value={String(value('full_day_hours') ?? 8)} onChange={(e) => set('full_day_hours', Number(e.target.value))} disabled={!canEdit} />
        </Field>
        <Field label="Flag anything under" htmlFor="pl-half" help="Hours. Shorter days are marked for someone to check.">
          <Input id="pl-half" type="number" step="0.5" min="0.5" value={String(value('half_day_hours') ?? 4)} onChange={(e) => set('half_day_hours', Number(e.target.value))} disabled={!canEdit} />
        </Field>
        <Field
          label="Re-check the last"
          htmlFor="pl-recheck"
          className="sm:col-span-2"
          help={`Days. Once that long has passed, one run reads the whole window again instead of just yesterday — it is how a day someone corrected in Punchly afterwards gets noticed.${
            s?.last_reconcile_at ? ` Last re-checked ${dateTimeDMY(s.last_reconcile_at)}.` : ''
          }`}
        >
          <Input id="pl-recheck" type="number" step="1" min="2" max="366" value={String(value('reconcile_days') ?? 14)} onChange={(e) => set('reconcile_days', Number(e.target.value))} disabled={!canEdit} />
        </Field>

        <label className="flex items-start gap-2 text-sm sm:col-span-2">
          <Checkbox checked={Boolean(value('is_enabled'))} onChange={(e) => set('is_enabled', e.target.checked)} disabled={!canEdit} />
          <span>
            Read Punchly automatically
            <span className="block text-xs text-muted-foreground">Twice an hour, plus a re-read of yesterday — a phone out of signal delivers this morning's punch tonight.</span>
          </span>
        </label>
        <label className="flex items-start gap-2 text-sm sm:col-span-2">
          <Checkbox checked={Boolean(value('auto_wage'))} onChange={(e) => set('auto_wage', e.target.checked)} disabled={!canEdit} />
          <span>
            Work the wage out from the daily wage
            <span className="block text-xs text-muted-foreground">A full day pays the staff member's daily wage, half a day pays half. Set each person's wage under Users.</span>
          </span>
        </label>
        <label className="flex items-start gap-2 text-sm sm:col-span-2">
          <Checkbox checked={Boolean(value('store_location'))} onChange={(e) => set('store_location', e.target.checked)} disabled={!canEdit} />
          <span>
            Keep the punch location
            <span className="block text-xs text-muted-foreground">
              Punchly sends the GPS position of each punch. That is personal data under the DPDP Act — leave this off unless you
              have told the staff and have a reason to keep it.
            </span>
          </span>
        </label>

        <div className="flex flex-wrap items-center gap-2 sm:col-span-2">
          <Button type="submit" size="sm" disabled={!canEdit || save.isPending}>
            <Save /> {save.isPending ? 'Saving…' : 'Save settings'}
          </Button>
          <Button type="button" variant="outline" size="sm" onClick={() => sync.mutate()} disabled={!canEdit || !s?.has_api_key || sync.isPending}>
            <RefreshCw className={cn(sync.isPending && 'animate-spin')} /> {sync.isPending ? 'Reading…' : 'Read Punchly now'}
          </Button>
          {s?.last_sync_at && <span className="text-xs text-muted-foreground">Last read {dateTimeDMY(s.last_sync_at)}</span>}
        </div>
        {s?.last_sync_note && <p className="text-xs text-muted-foreground sm:col-span-2">{s.last_sync_note}</p>}
        {lastSync?.staff && lastSync.staff.unmatched_count > 0 && (
          <p className="text-xs text-amber-700 dark:text-amber-500 sm:col-span-2">
            {lastSync.staff.unmatched_count} Punchly {lastSync.staff.unmatched_count === 1 ? 'person is' : 'people are'} not matched to
            anyone here — {lastSync.staff.unmatched.map((u) => `${u.full_name} (${u.staff_id})`).join(', ')}. Match them below, or their
            punches are ignored.
          </p>
        )}
      </form>

      <Roster canEdit={canEdit} isOwner={me.data?.role === 'owner'} unmatched={lastSync?.staff?.unmatched ?? []} />
    </section>
  );
}

/**
 * Who is who. Punchly's own staff_id can be renamed by whoever runs Punchly, so people
 * are tied on its user_id, which cannot. An exact name match links itself on the first
 * read; everything else is matched here.
 */
function Roster({
  canEdit,
  isOwner,
  unmatched,
}: {
  canEdit: boolean;
  isOwner: boolean;
  unmatched: { user_id: string; staff_id: string; full_name: string }[];
}) {
  const qc = useQueryClient();
  const roster = useQuery({ queryKey: ROSTER_KEY, queryFn: punchlyRoster });
  const link = useMutation({
    mutationFn: ({ staffId, userId, code }: { staffId: string; userId: string | null; code?: string | null }) =>
      linkPunchlyStaff(staffId, userId, code),
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ROSTER_KEY });
      toast({ title: 'Staff linked' });
    },
    onError: (e) => toastError(e, 'Could not link'),
  });
  const forget = useMutation({
    mutationFn: forgetStaffAttendance,
    onSuccess: async (days) => {
      await qc.invalidateQueries({ queryKey: ROSTER_KEY });
      await qc.invalidateQueries({ queryKey: ['attendance'] });
      toast({ title: `${days} day${days === 1 ? '' : 's'} erased`, description: 'The Punchly link went with them, so the next sync will not bring them back.' });
    },
    onError: (e) => toastError(e, 'Could not erase'),
  });

  if (roster.isLoading) return <Spinner />;
  if (roster.error) return <p role="alert" className="text-sm text-destructive">{roster.error.message}</p>;
  const rows = roster.data ?? [];

  return (
    <div>
      <h3 className="mb-1 text-sm font-medium">Who is who</h3>
      <p className="mb-2 max-w-2xl text-sm text-muted-foreground">
        A punch only becomes attendance if the person it belongs to is on this list. Anyone left unmatched is simply skipped —
        nothing is lost, and matching them later brings their whole history in on the next read.
      </p>
      <div className="max-w-3xl overflow-x-auto rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Staff</TableHead>
              <TableHead>Punchly person</TableHead>
              <TableHead>Code</TableHead>
              <TableHead className="w-12" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => {
              const options = unmatched.filter((u) => u.user_id !== r.punchly_user_id);
              return (
                <TableRow key={r.id ?? ''}>
                  <TableCell className="font-medium">
                    {r.full_name}
                    {r.designation && <span className="block text-xs text-muted-foreground">{r.designation}</span>}
                  </TableCell>
                  <TableCell>
                    {r.is_linked ? (
                      <Badge variant="secondary"><Link2 className="mr-1 h-3 w-3" aria-hidden /> {r.punchly_user_id}</Badge>
                    ) : options.length && canEdit ? (
                      <NativeSelect
                        className="h-8 w-56"
                        aria-label={`Link ${r.full_name} to a Punchly person`}
                        defaultValue=""
                        onChange={(e) => {
                          const u = options.find((o) => o.user_id === e.target.value);
                          if (u && r.id) link.mutate({ staffId: r.id, userId: u.user_id, code: u.staff_id });
                        }}
                      >
                        <option value="">Not matched</option>
                        {options.map((u) => <option key={u.user_id} value={u.user_id}>{u.full_name} ({u.staff_id})</option>)}
                      </NativeSelect>
                    ) : (
                      <span className="text-sm text-muted-foreground">Not matched</span>
                    )}
                  </TableCell>
                  <TableCell className="text-sm text-muted-foreground">{r.punchly_staff_id ?? '—'}</TableCell>
                  <TableCell className="whitespace-nowrap">
                    {r.is_linked && canEdit && (
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={`Unlink ${r.full_name} from Punchly`}
                        onClick={() => r.id && link.mutate({ staffId: r.id, userId: null })}
                        disabled={link.isPending}
                      >
                        <Link2Off />
                      </Button>
                    )}
                    {isOwner && (
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={`Erase ${r.full_name}'s attendance`}
                        title="Erase this person's attendance for good"
                        onClick={() => {
                          if (!r.id) return;
                          const ok = window.confirm(
                            `Erase every attendance day recorded for ${r.full_name}, and unlink them from Punchly?\n\nThis cannot be undone, and their punches will not come back on the next sync.`,
                          );
                          if (ok) forget.mutate(r.id);
                        }}
                        disabled={forget.isPending}
                      >
                        <Trash2 />
                      </Button>
                    )}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>
      {!unmatched.length && (
        <p className="mt-2 text-xs text-muted-foreground">
          Read Punchly above to see who it has on its books; anyone it cannot place turns into a choice on this list.
        </p>
      )}
    </div>
  );
}
