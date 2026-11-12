import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { AlertTriangle, Download, Pencil, Printer, RefreshCw, Wallet } from 'lucide-react';
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
import { amount, dateDMY, money, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { listStaff, receiptModesApi } from '@/features/setup/api';
import {
  attendanceRegister, listAdvances, payWages, saveAttendance, saveStaffAdvance, statusLabel, statusTone,
  STATUSES, syncPunchlyNow, wageRuns, wageSheet,
  type AttendStatus, type RegisterRow, type WageRow,
} from '../api';

const TABS = [
  { key: 'register', label: 'Daily register' },
  { key: 'wages', label: 'Days & wages' },
  { key: 'advances', label: 'Advances' },
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
      {tab === 'advances' ? (
        <Advances />
      ) : tab === 'register' ? (
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
  // The people on the roll, for the staff picker. staff_list() rather than the
  // old wage summary: a name does not need a month of wage arithmetic behind it.
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
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
                  {(staff.data ?? []).filter((p) => p.is_active).map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}
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
/**
 * The wage sheet, and paying it.
 *
 * This used to read attendanceSummary, which summed attendance.wage_amount —
 * a full day or half a day, and never a paisa of the overtime it had carefully
 * worked out from the punches. It now reads wage_sheet (db/73): overtime at
 * the shop's own multiplier when the shop has said to pay it, monthly-salary
 * staff beside daily-wage ones, and outstanding advances cut from the net.
 *
 * And it can be PAID, which puts it in the books. Before db/73 the WAGES
 * account had never had a single posting: the sheet was read and the money
 * went out of the till with nothing to show for it in the P&L.
 */
function Wages({ from, to, setFrom, setTo }: { from: string; to: string; setFrom: (v: string) => void; setTo: (v: string) => void }) {
  const perms = usePermissions();
  const rows = useQuery({ queryKey: ['attendance', 'wage-sheet', from, to], queryFn: () => wageSheet(from, to) });
  const runs = useQuery({ queryKey: ['attendance', 'wage-runs'], queryFn: wageRuns });
  const [paying, setPaying] = useState(false);
  const data: WageRow[] = rows.data ?? [];

  const sum = (pick: (r: WageRow) => unknown) => data.reduce((t, r) => t + toNumber(pick(r) as number), 0);
  const basic = sum((r) => r.basic);
  const otPay = sum((r) => r.ot_amount);
  const advance = sum((r) => r.advance_due);
  const net = sum((r) => r.net);

  // A period already paid is shown as paid rather than offered again — the
  // database refuses a second run, and finding that out by pressing the button
  // is a worse way to learn it.
  const alreadyPaid = (runs.data ?? []).find((w) => w.period_from === from && w.period_to === to);
  const canPay = perms.canEdit('payments') && !alreadyPaid && data.some((r) => toNumber(r.net) > 0);

  return (
    <section className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <Range from={from} to={to} setFrom={setFrom} setTo={setTo} prefix="wage" />
        <Actions
          disabled={!data.length}
          onExport={() =>
            exportToExcel(`wages-${from}-to-${to}`, data.map((r) => ({
              Staff: r.full_name, Role: r.role_name, Paid: r.pay_type === 'monthly' ? 'monthly' : 'daily',
              Rate: toNumber(r.day_rate), Present: r.present, 'Half days': r.half_days,
              'Paid leave': r.paid_leave, 'Unpaid leave': r.unpaid_leave, Absent: r.absent,
              Holidays: r.holidays, 'Week offs': r.week_offs, 'Days paid': toNumber(r.days_paid),
              Hours: toNumber(r.worked_hours), 'OT hours': toNumber(r.ot_hours),
              Basic: toNumber(r.basic), 'OT pay': toNumber(r.ot_amount), Gross: toNumber(r.gross),
              'Advance due': toNumber(r.advance_due), Net: toNumber(r.net), 'To check': r.needs_review,
            })))
          }
        />
        {canPay && (
          <Button size="sm" className="h-8" onClick={() => setPaying(true)}>
            <Wallet className="mr-1 h-4 w-4" /> Pay these wages
          </Button>
        )}
      </div>

      {alreadyPaid ? (
        <p className="rounded-md border border-emerald-500/40 bg-emerald-500/10 p-3 text-sm">
          <strong>Paid on {dateDMY(alreadyPaid.paid_on)}</strong> — {alreadyPaid.staff_count} people,{' '}
          {money(alreadyPaid.total_net)} handed over
          {toNumber(alreadyPaid.total_advance) > 0 && <> after cutting {money(alreadyPaid.total_advance)} of advances</>}. It
          is in the books under Labour &amp; wages, and this period cannot be paid again.
        </p>
      ) : (
        <p className="max-w-3xl text-sm text-muted-foreground">
          What each person has earned for the period. Paying it writes a payment against each person, puts the wage bill in
          the P&amp;L under Labour &amp; wages, and clears any advance they have taken.
          {!perms.canEdit('payments') && ' Paying needs the Payments right as well as Attendance.'}
        </p>
      )}

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
                <TableHead className="text-right">Rate</TableHead>
                <TableHead className="text-right">Days</TableHead>
                <TableHead className="text-right">OT hrs</TableHead>
                <TableHead className="text-right">Basic</TableHead>
                <TableHead className="text-right">OT pay</TableHead>
                <TableHead className="text-right">Advance</TableHead>
                <TableHead className="text-right">Net</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {data.map((r) => (
                <TableRow key={r.staff_id ?? ''}>
                  <TableCell className="font-medium">
                    {r.full_name}
                    {r.pay_type === 'monthly' && <Badge variant="outline" className="ml-2">monthly</Badge>}
                    {!!r.needs_review && (
                      <span className="ml-1.5 text-xs text-amber-700 dark:text-amber-500">{r.needs_review} to check</span>
                    )}
                    <span className="block text-xs text-muted-foreground">
                      {r.present} present
                      {!!r.half_days && `, ${r.half_days} half`}
                      {!!r.paid_leave && `, ${r.paid_leave} paid leave`}
                      {!!r.unpaid_leave && `, ${r.unpaid_leave} unpaid`}
                      {!!r.absent && `, ${r.absent} absent`}
                    </span>
                  </TableCell>
                  <TableCell className="text-right">{amount(r.day_rate)}</TableCell>
                  <TableCell className="text-right">{qty(r.days_paid)}</TableCell>
                  <TableCell className="text-right">{qty(r.ot_hours)}</TableCell>
                  <TableCell className="text-right">{amount(r.basic)}</TableCell>
                  <TableCell className="text-right">{amount(r.ot_amount)}</TableCell>
                  <TableCell className="text-right">{toNumber(r.advance_due) > 0 ? `−${amount(r.advance_due)}` : ''}</TableCell>
                  <TableCell className="text-right font-medium">{amount(r.net)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell colSpan={4}>Total</TableCell>
                <TableCell className="text-right">{amount(basic)}</TableCell>
                <TableCell className="text-right">{amount(otPay)}</TableCell>
                <TableCell className="text-right">{advance > 0 ? `−${amount(advance)}` : ''}</TableCell>
                <TableCell className="text-right font-semibold">{amount(net)}</TableCell>
              </TableRow>
            </TableFooter>
          </Table>
        </div>
      )}

      {paying && <PayWagesDialog from={from} to={to} net={net} count={data.filter((r) => toNumber(r.net) > 0).length} onClose={() => setPaying(false)} />}
    </section>
  );
}

function PayWagesDialog({ from, to, net, count, onClose }: { from: string; to: string; net: number; count: number; onClose: () => void }) {
  const qc = useQueryClient();
  const modes = useQuery({ queryKey: ['setup', 'receipt_modes'], queryFn: receiptModesApi.list });
  const [modeId, setModeId] = useState('');
  const [paidOn, setPaidOn] = useState(toISODate());
  const pay = useMutation({
    mutationFn: () => payWages({ period_from: from, period_to: to, paid_on: paidOn, mode_id: modeId }),
    onSuccess: async (r) => {
      await qc.invalidateQueries({ queryKey: ['attendance'] });
      await qc.invalidateQueries({ queryKey: ['payments'] });
      toast({
        title: `${r.staff_count} paid, ${money(r.net_paid)} out`,
        description: r.advance_recovered > 0 ? `${money(r.advance_recovered)} of advances cleared` : undefined,
      });
      onClose();
    },
    onError: (e) => toastError(e, 'Could not pay the wages'),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Pay wages for {dateDMY(from)} to {dateDMY(to)}</DialogTitle>
        </DialogHeader>
        <form className="space-y-3" onSubmit={(ev) => { ev.preventDefault(); pay.mutate(); }}>
          <p className="text-sm text-muted-foreground">
            {count} {count === 1 ? 'person' : 'people'}, {money(net)} to hand over. Each gets a payment of their own, the wage
            bill goes to Labour &amp; wages, and any advance they owe is cleared out of it.
          </p>
          <Field label="Paid from" htmlFor="pw-mode">
            <NativeSelect id="pw-mode" value={modeId} onChange={(e) => setModeId(e.target.value)} required>
              <option value="">Choose…</option>
              {(modes.data ?? []).filter((m) => m.is_collection && !m.is_cheque).map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Paid on" htmlFor="pw-date">
            <Input id="pw-date" type="date" value={paidOn} onChange={(e) => setPaidOn(e.target.value)} required />
          </Field>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" disabled={!modeId || pay.isPending}>{pay.isPending ? 'Paying…' : 'Pay'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------- advances
/**
 * Money handed to somebody against their wages — two thousand on the 8th, cut
 * at the month end. The most ordinary transaction in the factory, and until
 * db/73 there was nowhere to write it down.
 *
 * It is not an expense when it goes out: it is money they owe back, so it sits
 * in Staff advances until a wage run clears it. The wage sheet shows what is
 * still owed beside what they have earned, and takes the oldest first.
 */
function Advances() {
  const perms = usePermissions();
  const rows = useQuery({ queryKey: ['attendance', 'advances'], queryFn: listAdvances });
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const [adding, setAdding] = useState(false);
  const data = rows.data ?? [];
  const nameOf = (id: string) => (staff.data ?? []).find((p) => p.id === id)?.full_name ?? '—';
  const outstanding = data.reduce((t, a) => t + (toNumber(a.amount) - toNumber(a.recovered)), 0);

  return (
    <section className="space-y-3">
      <div className="no-print flex flex-wrap items-center justify-between gap-2">
        <p className="max-w-2xl text-sm text-muted-foreground">
          Advances against wages. What is still owed is cut from the next wage run, oldest first, and never more than the
          person earned that month — nobody is handed a negative payslip.
        </p>
        {perms.canEdit('attendance') && (
          <Button size="sm" className="h-8" onClick={() => setAdding(true)}>
            <Wallet className="mr-1 h-4 w-4" /> Give an advance
          </Button>
        )}
      </div>

      {rows.isLoading ? (
        <Spinner />
      ) : rows.error ? (
        <p role="alert" className="text-sm text-destructive">{rows.error.message}</p>
      ) : !data.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
          No advances given.
        </p>
      ) : (
        <div className="overflow-x-auto rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Date</TableHead>
                <TableHead>Staff</TableHead>
                <TableHead className="text-right">Given</TableHead>
                <TableHead className="text-right">Recovered</TableHead>
                <TableHead className="text-right">Still owed</TableHead>
                <TableHead>Note</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {data.map((a) => (
                <TableRow key={a.id}>
                  <TableCell>{dateDMY(a.advance_date)}</TableCell>
                  <TableCell className="font-medium">{nameOf(a.staff_id)}</TableCell>
                  <TableCell className="text-right">{amount(a.amount)}</TableCell>
                  <TableCell className="text-right">{amount(a.recovered)}</TableCell>
                  <TableCell className="text-right font-medium">
                    {amount(toNumber(a.amount) - toNumber(a.recovered))}
                  </TableCell>
                  <TableCell className="text-xs text-muted-foreground">{a.notes ?? ''}</TableCell>
                </TableRow>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell colSpan={4}>Still owed in total</TableCell>
                <TableCell className="text-right font-semibold">{amount(outstanding)}</TableCell>
                <TableCell />
              </TableRow>
            </TableFooter>
          </Table>
        </div>
      )}

      {adding && <AdvanceDialog onClose={() => setAdding(false)} />}
    </section>
  );
}

function AdvanceDialog({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const modes = useQuery({ queryKey: ['setup', 'receipt_modes'], queryFn: receiptModesApi.list });
  const [staffId, setStaffId] = useState('');
  const [amt, setAmt] = useState('');
  const [date, setDate] = useState(toISODate());
  const [modeId, setModeId] = useState('');
  const [notes, setNotes] = useState('');
  const save = useMutation({
    mutationFn: () =>
      saveStaffAdvance({
        staff_id: staffId,
        amount: Number(amt),
        advance_date: date,
        mode_id: modeId || null,
        ...(notes ? { notes } : {}),
      }),
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['attendance'] });
      await qc.invalidateQueries({ queryKey: ['accounts'] });
      toast({ title: 'Advance recorded', description: 'It will be cut from the next wage run.' });
      onClose();
    },
    onError: (e) => toastError(e, 'Could not record the advance'),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>Advance against wages</DialogTitle></DialogHeader>
        <form className="space-y-3" onSubmit={(ev) => { ev.preventDefault(); save.mutate(); }}>
          <Field label="Staff" htmlFor="ad-staff">
            <NativeSelect id="ad-staff" value={staffId} onChange={(e) => setStaffId(e.target.value)} required>
              <option value="">Choose…</option>
              {(staff.data ?? []).filter((p) => p.is_active).map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Amount" htmlFor="ad-amt">
            <Input id="ad-amt" type="number" min="1" step="1" value={amt} onChange={(e) => setAmt(e.target.value)} required />
          </Field>
          <Field label="Date" htmlFor="ad-date">
            <Input id="ad-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
          </Field>
          <Field
            label="Paid from"
            htmlFor="ad-mode"
            help="Leave blank if it came out of a pocket — the advance is still recovered, it just does not touch the cash book."
          >
            <NativeSelect id="ad-mode" value={modeId} onChange={(e) => setModeId(e.target.value)}>
              <option value="">Not recorded</option>
              {(modes.data ?? []).filter((m) => m.is_collection && !m.is_cheque).map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Note" htmlFor="ad-note">
            <Input id="ad-note" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="For his daughter's fees" />
          </Field>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" disabled={!staffId || !Number(amt) || save.isPending}>
              {save.isPending ? 'Saving…' : 'Record'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
