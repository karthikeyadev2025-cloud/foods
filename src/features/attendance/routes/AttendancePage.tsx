import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { AlertTriangle, Download, Pencil, Printer, RefreshCw } from 'lucide-react';
import { useMemo, useState } from 'react';
import { NavLink } from 'react-router-dom';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import {
  attendanceRegister, attendanceSummary, saveAttendance, statusLabel, statusTone, STATUSES, syncPunchlyNow,
  type AttendStatus, type RegisterRow, type SummaryRow,
} from '../api';

const TABS = [
  { key: 'register', label: 'Daily register' },
  { key: 'wages', label: 'Days & wages' },
] as const;
export type AttendanceTab = (typeof TABS)[number]['key'];

function monthStart(): string {
  const d = new Date();
  return toISODate(new Date(d.getFullYear(), d.getMonth(), 1));
}

/**
 * Attendance: what the punches came to, day by day and totalled for the month.
 * Rows arrive from Punchly on their own (Setup → Attendance) and can be typed or
 * corrected here; a row touched by hand is never overwritten by a later sync.
 */
export function AttendancePage({ tab = 'register' }: { tab?: AttendanceTab }) {
  const perms = usePermissions();
  const me = useMe();
  const [from, setFrom] = useState(monthStart);
  const [to, setTo] = useState(() => toISODate());
  const canEdit = perms.canEdit('attendance');
  // Syncing rewrites staff rows as it links people, so it is the owner's and admin's
  const canSync = me.data?.role === 'owner' || me.data?.role === 'admin';
  const qc = useQueryClient();

  const sync = useMutation({
    mutationFn: syncPunchlyNow,
    onSuccess: async (rows) => {
      await qc.invalidateQueries({ queryKey: ['attendance'] });
      const failed = rows.find((r) => r.error);
      if (failed) return toast({ title: 'Punchly could not be read', description: failed.error, variant: 'destructive' });
      const written = rows.reduce((s, r) => s + r.written, 0);
      const left = rows.find((r) => r.backfill_left)?.backfill_left;
      toast({
        title: written ? `${written} day${written === 1 ? '' : 's'} updated` : 'Nothing new to bring in',
        description: left ? `History still loading — the next run continues from ${dateDMY(left)}.` : undefined,
      });
    },
    onError: (e) => toastError(e, 'Could not reach Punchly'),
  });

  return (
    <div className="space-y-3">
      <PageHeader
        title="Attendance"
        description="One row per person per day, folded from the Punchly punches — first check-in, last check-out, hours, overtime and the day's wage. Anything typed here stays typed."
        actions={
          canSync && (
            <Button variant="outline" size="sm" onClick={() => sync.mutate()} disabled={sync.isPending}>
              <RefreshCw className={cn(sync.isPending && 'animate-spin')} /> {sync.isPending ? 'Reading Punchly…' : 'Sync now'}
            </Button>
          )
        }
      />
      <nav className="no-print flex flex-wrap gap-1 border-b" aria-label="Attendance">
        {TABS.map((t) => (
          <NavLink
            key={t.key}
            to={t.key === 'register' ? '/attendance' : `/attendance/${t.key}`}
            end
            className={({ isActive }) =>
              cn('-mb-px border-b-2 px-3 py-1.5 text-sm', isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')
            }
          >
            {t.label}
          </NavLink>
        ))}
      </nav>
      {tab === 'register' ? (
        <Register from={from} to={to} setFrom={setFrom} setTo={setTo} canEdit={canEdit} />
      ) : (
        <Wages from={from} to={to} setFrom={setFrom} setTo={setTo} />
      )}
    </div>
  );
}

function Range({ from, to, setFrom, setTo, prefix }: { from: string; to: string; setFrom: (v: string) => void; setTo: (v: string) => void; prefix: string }) {
  return (
    <>
      <Field label="From" htmlFor={`${prefix}-from`}>
        <Input id={`${prefix}-from`} type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} />
      </Field>
      <Field label="To" htmlFor={`${prefix}-to`}>
        <Input id={`${prefix}-to`} type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} />
      </Field>
    </>
  );
}

function Actions({ onExport, disabled }: { onExport: () => void; disabled: boolean }) {
  return (
    <span className="no-print ml-auto flex items-center gap-2 pb-1">
      <Button variant="outline" size="sm" onClick={() => window.print()} disabled={disabled}>
        <Printer /> Print
      </Button>
      <Button variant="outline" size="sm" onClick={onExport} disabled={disabled}>
        <Download /> Excel
      </Button>
    </span>
  );
}

// ---------------------------------------------------------------- daily register
function Register({ from, to, setFrom, setTo, canEdit }: { from: string; to: string; setFrom: (v: string) => void; setTo: (v: string) => void; canEdit: boolean }) {
  const [onlyReview, setOnlyReview] = useState(false);
  const [editing, setEditing] = useState<RegisterRow | null>(null);
  const [adding, setAdding] = useState(false);
  const rows = useQuery({ queryKey: ['attendance', 'register', from, to], queryFn: () => attendanceRegister(from, to) });
  const shown = useMemo(() => (onlyReview ? (rows.data ?? []).filter((r) => r.needs_review) : rows.data ?? []), [rows.data, onlyReview]);
  const flagged = (rows.data ?? []).filter((r) => r.needs_review).length;

  return (
    <section className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <Range from={from} to={to} setFrom={setFrom} setTo={setTo} prefix="reg" />
        <Field label="Show" htmlFor="reg-filter">
          <NativeSelect id="reg-filter" className="h-8 w-52" value={onlyReview ? 'review' : 'all'} onChange={(e) => setOnlyReview(e.target.value === 'review')}>
            <option value="all">Every day</option>
            <option value="review">Only days to check{flagged ? ` (${flagged})` : ''}</option>
          </NativeSelect>
        </Field>
        {canEdit && (
          <Button size="sm" variant="outline" onClick={() => setAdding(true)}>
            <Pencil /> Enter a day
          </Button>
        )}
        <Actions
          disabled={!shown.length}
          onExport={() =>
            exportToExcel(`attendance-${from}-to-${to}`, shown.map((r) => ({
              Date: dateDMY(r.work_date), Staff: r.full_name, Status: statusLabel(r.status),
              In: r.in_time ?? '', Out: r.out_time ?? '', Hours: toNumber(r.worked_hours), OT: toNumber(r.ot_hours),
              Wage: toNumber(r.wage_amount), Branch: r.branch_name ?? '', Shift: r.shift_name ?? '',
              From: r.source === 'punchly' ? 'Punchly' : 'Typed', Check: r.needs_review ? 'yes' : '', Note: r.notes ?? '',
            })))
          }
        />
      </div>

      {rows.isLoading ? (
        <Spinner />
      ) : rows.error ? (
        <p role="alert" className="text-sm text-destructive">{rows.error.message}</p>
      ) : !shown.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
          No attendance for these dates. Punchly fills this in every half hour once it is switched on under Setup → Attendance.
        </p>
      ) : (
        <div className="overflow-x-auto rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Date</TableHead>
                <TableHead>Staff</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>In</TableHead>
                <TableHead>Out</TableHead>
                <TableHead className="text-right">Hours</TableHead>
                <TableHead className="text-right">OT</TableHead>
                <TableHead className="text-right">Wage</TableHead>
                <TableHead>From</TableHead>
                {canEdit && <TableHead className="no-print w-12" />}
              </TableRow>
            </TableHeader>
            <TableBody>
              {shown.map((r) => (
                <TableRow key={r.id ?? `${r.staff_id}-${r.work_date}`} className={cn(r.needs_review && 'bg-amber-50 dark:bg-amber-950/20')}>
                  <TableCell className="whitespace-nowrap">{dateDMY(r.work_date)}</TableCell>
                  <TableCell className="font-medium">
                    {r.full_name}
                    {r.needs_review && (
                      <span className="ml-1.5 inline-flex items-center gap-1 text-xs text-amber-700 dark:text-amber-500">
                        <AlertTriangle className="h-3 w-3" aria-hidden /> check
                      </span>
                    )}
                  </TableCell>
                  <TableCell><Badge variant={statusTone(r.status)}>{statusLabel(r.status)}</Badge></TableCell>
                  <TableCell>{r.in_time?.slice(0, 5) ?? '—'}</TableCell>
                  <TableCell>{r.out_time?.slice(0, 5) ?? '—'}</TableCell>
                  <TableCell className="text-right">{r.worked_hours == null ? '—' : qty(r.worked_hours)}</TableCell>
                  <TableCell className="text-right">{toNumber(r.ot_hours) ? qty(r.ot_hours) : '—'}</TableCell>
                  <TableCell className="text-right">{amount(r.wage_amount)}</TableCell>
                  <TableCell className="text-xs text-muted-foreground">{r.source === 'punchly' ? 'Punchly' : 'Typed'}</TableCell>
                  {canEdit && (
                    <TableCell className="no-print">
                      <Button variant="ghost" size="icon" aria-label={`Edit ${r.full_name} on ${dateDMY(r.work_date)}`} onClick={() => setEditing(r)}>
                        <Pencil />
                      </Button>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {(editing || adding) && <DayDialog row={editing} onClose={() => { setEditing(null); setAdding(false); }} />}
    </section>
  );
}

/** Type a day in, or correct one Punchly got wrong. Saving marks the row as typed. */
function DayDialog({ row, onClose }: { row: RegisterRow | null; onClose: () => void }) {
  const qc = useQueryClient();
  const staff = useQuery({ queryKey: ['attendance', 'staff-options'], queryFn: () => attendanceSummary(toISODate(), toISODate()) });
  const [staffId, setStaffId] = useState(row?.staff_id ?? '');
  const [workDate, setWorkDate] = useState(row?.work_date ?? toISODate());
  const [status, setStatus] = useState<AttendStatus>(row?.status ?? 'present');
  const [inTime, setInTime] = useState(row?.in_time?.slice(0, 5) ?? '');
  const [outTime, setOutTime] = useState(row?.out_time?.slice(0, 5) ?? '');
  const [ot, setOt] = useState(String(toNumber(row?.ot_hours) || ''));
  const [wage, setWage] = useState(row ? String(toNumber(row.wage_amount)) : '');
  const [notes, setNotes] = useState(row?.notes ?? '');

  const save = useMutation({
    mutationFn: () =>
      saveAttendance({
        staff_id: staffId,
        work_date: workDate,
        status,
        in_time: inTime || null,
        out_time: outTime || null,
        ot_hours: ot ? Number(ot) : 0,
        // blank means "work it out from the daily wage"; a figure typed here wins
        wage_amount: wage === '' ? null : Number(wage),
        notes: notes || null,
      }),
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['attendance'] });
      toast({ title: 'Day saved', description: 'A later Punchly sync will leave this row alone.' });
      onClose();
    },
    onError: (e) => toastError(e, 'Could not save the day'),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader><DialogTitle>{row ? `${row.full_name} — ${dateDMY(row.work_date)}` : 'Enter a day'}</DialogTitle></DialogHeader>
        <form
          className="grid gap-3 sm:grid-cols-2"
          onSubmit={(ev) => { ev.preventDefault(); save.mutate(); }}
        >
          {!row && (
            <>
              <Field label="Staff" htmlFor="att-staff">
                <NativeSelect id="att-staff" value={staffId} onChange={(e) => setStaffId(e.target.value)} required>
                  <option value="">Choose…</option>
                  {(staff.data ?? []).map((s) => <option key={s.staff_id ?? ''} value={s.staff_id ?? ''}>{s.full_name}</option>)}
                </NativeSelect>
              </Field>
              <Field label="Date" htmlFor="att-date">
                <Input id="att-date" type="date" value={workDate} onChange={(e) => setWorkDate(e.target.value)} required />
              </Field>
            </>
          )}
          <Field label="Status" htmlFor="att-status">
            <NativeSelect id="att-status" value={status} onChange={(e) => setStatus(e.target.value as AttendStatus)}>
              {STATUSES.map((s) => <option key={s.key} value={s.key}>{s.label}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Overtime hours" htmlFor="att-ot">
            <Input id="att-ot" type="number" step="0.25" min="0" value={ot} onChange={(e) => setOt(e.target.value)} />
          </Field>
          <Field label="In" htmlFor="att-in"><Input id="att-in" type="time" value={inTime} onChange={(e) => setInTime(e.target.value)} /></Field>
          <Field label="Out" htmlFor="att-out"><Input id="att-out" type="time" value={outTime} onChange={(e) => setOutTime(e.target.value)} /></Field>
          <Field label="Wage" htmlFor="att-wage" help="Leave blank to take it from the daily wage." className="sm:col-span-2">
            <Input id="att-wage" type="number" step="0.01" min="0" value={wage} onChange={(e) => setWage(e.target.value)} />
          </Field>
          <Field label="Note" htmlFor="att-note" className="sm:col-span-2">
            <Input id="att-note" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Told the mestry in the morning" />
          </Field>
          <DialogFooter className="sm:col-span-2">
            <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" disabled={!staffId || save.isPending}>{save.isPending ? 'Saving…' : 'Save'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------- days and wages
function Wages({ from, to, setFrom, setTo }: { from: string; to: string; setFrom: (v: string) => void; setTo: (v: string) => void }) {
  const rows = useQuery({ queryKey: ['attendance', 'summary', from, to], queryFn: () => attendanceSummary(from, to) });
  const data: SummaryRow[] = rows.data ?? [];
  const total = data.reduce((s, r) => s + toNumber(r.wage), 0);

  return (
    <section className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <Range from={from} to={to} setFrom={setFrom} setTo={setTo} prefix="wage" />
        <Actions
          disabled={!data.length}
          onExport={() =>
            exportToExcel(`wages-${from}-to-${to}`, data.map((r) => ({
              Staff: r.full_name, Mestry: r.is_mestry ? 'yes' : '', 'Daily wage': toNumber(r.daily_wage),
              Present: r.present, 'Half days': r.half_days, Absent: r.absent, Leave: r.leave_days, Holidays: r.holidays,
              Hours: toNumber(r.worked_hours), OT: toNumber(r.ot_hours), Wage: toNumber(r.wage), 'To check': r.needs_review,
            })))
          }
        />
      </div>
      <p className="max-w-2xl text-sm text-muted-foreground">
        What each person is owed for the period, on the days recorded. Nothing here is posted to the books — an actual payment is
        made under Payments, against the staff member.
      </p>

      {rows.isLoading ? (
        <Spinner />
      ) : rows.error ? (
        <p role="alert" className="text-sm text-destructive">{rows.error.message}</p>
      ) : !data.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No staff on the roll.</p>
      ) : (
        <div className="overflow-x-auto rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Staff</TableHead>
                <TableHead className="text-right">Daily wage</TableHead>
                <TableHead className="text-right">Present</TableHead>
                <TableHead className="text-right">Half</TableHead>
                <TableHead className="text-right">Absent</TableHead>
                <TableHead className="text-right">Leave</TableHead>
                <TableHead className="text-right">Hours</TableHead>
                <TableHead className="text-right">OT</TableHead>
                <TableHead className="text-right">Wage</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {data.map((r) => (
                <TableRow key={r.staff_id ?? ''}>
                  <TableCell className="font-medium">
                    {r.full_name}
                    {r.is_mestry && <Badge variant="outline" className="ml-2">mestry</Badge>}
                    {!!r.needs_review && (
                      <span className="ml-1.5 text-xs text-amber-700 dark:text-amber-500">{r.needs_review} to check</span>
                    )}
                  </TableCell>
                  <TableCell className="text-right">{amount(r.daily_wage)}</TableCell>
                  <TableCell className="text-right">{r.present}</TableCell>
                  <TableCell className="text-right">{r.half_days}</TableCell>
                  <TableCell className="text-right">{r.absent}</TableCell>
                  <TableCell className="text-right">{r.leave_days}</TableCell>
                  <TableCell className="text-right">{qty(r.worked_hours)}</TableCell>
                  <TableCell className="text-right">{qty(r.ot_hours)}</TableCell>
                  <TableCell className="text-right font-medium">{amount(r.wage)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell colSpan={8}>Total</TableCell>
                <TableCell className="text-right font-semibold">{amount(total)}</TableCell>
              </TableRow>
            </TableFooter>
          </Table>
        </div>
      )}
    </section>
  );
}
