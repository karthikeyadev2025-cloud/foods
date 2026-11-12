import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Plus } from 'lucide-react';
import { useEffect, useState } from 'react';
import { DeleteButton } from '@/components/DeleteButton';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import {
  deleteHoliday,
  getPunchlySettings,
  listHolidays,
  listLeaveTypes,
  saveHoliday,
  saveLeaveType,
  savePunchlySettings,
} from '@/features/attendance/api';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { dateDMY, toISODate } from '@/lib/format';

const PAYROLL_KEY = ['attendance', 'punchly-settings'] as const;
const HOLIDAYS_KEY = ['attendance', 'holidays'] as const;
const LEAVE_KEY = ['attendance', 'leave-types'] as const;

const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/**
 * The rules the wage sheet works from.
 *
 * Overtime is OFF until the shop says otherwise, deliberately: db/73 gave the
 * sheet the ability to pay the hours it had been counting all along, and a
 * shop that has never paid overtime must not find its wage bill risen the
 * morning after the update. It says yes here, once.
 */
export function PayrollPanel() {
  const perms = usePermissions();
  const qc = useQueryClient();
  const settings = useQuery({ queryKey: PAYROLL_KEY, queryFn: getPunchlySettings });
  const canEdit = perms.canEdit('attendance');

  const [payOt, setPayOt] = useState(false);
  const [mult, setMult] = useState('1');
  const [weekOff, setWeekOff] = useState('');
  const [paidWeekOff, setPaidWeekOff] = useState(false);
  const [paidHolidays, setPaidHolidays] = useState(false);
  const [fullDay, setFullDay] = useState('8');

  useEffect(() => {
    const s = settings.data;
    if (!s) return;
    setPayOt(Boolean(s.pay_ot));
    setMult(String(s.ot_multiplier ?? 1));
    setWeekOff(s.week_off_dow === null || s.week_off_dow === undefined ? '' : String(s.week_off_dow));
    setPaidWeekOff(Boolean(s.paid_week_off));
    setPaidHolidays(Boolean(s.paid_holidays));
    setFullDay(String(s.full_day_hours ?? 8));
  }, [settings.data]);

  const save = useMutation({
    mutationFn: () =>
      savePunchlySettings({
        pay_ot: payOt,
        ot_multiplier: Number(mult),
        // '' means the shop works every day. Sent as a key either way, because
        // a missing key keeps whatever was there and could never clear it.
        week_off_dow: weekOff === '' ? null : Number(weekOff),
        paid_week_off: paidWeekOff,
        paid_holidays: paidHolidays,
        full_day_hours: Number(fullDay),
      }),
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: PAYROLL_KEY });
      await qc.invalidateQueries({ queryKey: ['attendance'] });
      toast({ title: 'Payroll rules saved', description: 'The wage sheet uses them from now on.' });
    },
    onError: (err) => toastError(err, 'Could not save the rules'),
  });

  return (
    <div className="space-y-8">
      <section className="space-y-3">
        <div>
          <h2 className="text-lg font-semibold">Wages &amp; overtime</h2>
          <p className="max-w-2xl text-sm text-muted-foreground">
            How the wage sheet works out what each person has earned. A person's own rate — daily wage or monthly salary —
            is on their record under Users.
          </p>
        </div>

        {settings.isLoading ? (
          <Spinner />
        ) : (
          <div className="grid max-w-3xl gap-3 sm:grid-cols-2">
            <Field label="A full day is" htmlFor="pr-full" help="Hours. Anything beyond this is overtime.">
              <Input id="pr-full" type="number" step="0.5" min="1" max="24" value={fullDay} disabled={!canEdit} onChange={(e) => setFullDay(e.target.value)} />
            </Field>
            <Field label="Weekly off" htmlFor="pr-weekoff" help="The day the shop is shut.">
              <NativeSelect id="pr-weekoff" value={weekOff} disabled={!canEdit} onChange={(e) => setWeekOff(e.target.value)}>
                <option value="">None — the shop works every day</option>
                {DAYS.map((d, i) => (
                  <option key={d} value={String(i)}>{d}</option>
                ))}
              </NativeSelect>
            </Field>

            <label className="flex items-start gap-2 text-sm sm:col-span-2">
              <Checkbox checked={payOt} disabled={!canEdit} onChange={(e) => setPayOt(e.target.checked)} />
              <span>
                <strong>Pay for overtime.</strong> The extra hours are counted from the punches whether this is on or off —
                this decides whether they are paid. Off until you turn it on, so the wage bill does not change by itself.
              </span>
            </label>

            {payOt && (
              <Field label="Overtime rate" htmlFor="pr-mult" help="1 = the same as ordinary hours, 1.5 = time and a half.">
                <Input id="pr-mult" type="number" step="0.25" min="0" max="3" value={mult} disabled={!canEdit} onChange={(e) => setMult(e.target.value)} />
              </Field>
            )}

            <label className="flex items-start gap-2 text-sm sm:col-span-2">
              <Checkbox checked={paidWeekOff} disabled={!canEdit} onChange={(e) => setPaidWeekOff(e.target.checked)} />
              <span>Daily-wage staff are paid for the weekly off</span>
            </label>
            <label className="flex items-start gap-2 text-sm sm:col-span-2">
              <Checkbox checked={paidHolidays} disabled={!canEdit} onChange={(e) => setPaidHolidays(e.target.checked)} />
              <span>
                Daily-wage staff are paid for festival holidays
                <span className="block text-xs text-muted-foreground">
                  A single holiday can be set the other way on its own line below. Monthly-salary staff are always paid for
                  both — that is what a monthly salary means.
                </span>
              </span>
            </label>

            {canEdit && (
              <div className="sm:col-span-2">
                <Button size="sm" onClick={() => save.mutate()} disabled={save.isPending}>
                  {save.isPending ? 'Saving…' : 'Save rules'}
                </Button>
              </div>
            )}
          </div>
        )}
      </section>

      <HolidaysSection canEdit={canEdit} />
      <LeaveTypesSection canEdit={canEdit} />
    </div>
  );
}

function HolidaysSection({ canEdit }: { canEdit: boolean }) {
  const qc = useQueryClient();
  const rows = useQuery({ queryKey: HOLIDAYS_KEY, queryFn: listHolidays });
  const [adding, setAdding] = useState(false);
  const [date, setDate] = useState(toISODate());
  const [name, setName] = useState('');

  const add = useMutation({
    mutationFn: () => saveHoliday({ holiday_date: date, name, is_paid: null }),
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: HOLIDAYS_KEY });
      await qc.invalidateQueries({ queryKey: ['attendance'] });
      setAdding(false);
      setName('');
      toast({ title: 'Holiday added' });
    },
    onError: (err) => toastError(err, 'Could not add the holiday'),
  });

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 className="text-lg font-semibold">Festival holidays</h2>
          <p className="max-w-2xl text-sm text-muted-foreground">
            Days the shop is shut besides the weekly off. The wage sheet reads this list, so a holiday has to be entered
            once rather than typed against every person.
          </p>
        </div>
        {canEdit && (
          <Button size="sm" onClick={() => setAdding(true)}>
            <Plus /> Add a holiday
          </Button>
        )}
      </div>

      {rows.isLoading ? (
        <Spinner />
      ) : !rows.data?.length ? (
        <p className="text-sm text-muted-foreground">No holidays entered.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Date</TableHead>
              <TableHead>What for</TableHead>
              <TableHead>Paid</TableHead>
              <TableHead className="no-print w-12" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.data.map((h) => (
              <TableRow key={h.id}>
                <TableCell>{dateDMY(h.holiday_date)}</TableCell>
                <TableCell className="font-medium">{h.name}</TableCell>
                <TableCell>
                  <Badge variant="outline">
                    {h.is_paid === null ? 'as set above' : h.is_paid ? 'paid' : 'unpaid'}
                  </Badge>
                </TableCell>
                <TableCell className="no-print">
                  {canEdit && (
                    <DeleteButton
                      label={`${h.name} on ${dateDMY(h.holiday_date)}`}
                      onDelete={async () => {
                        await deleteHoliday(h.id);
                        await qc.invalidateQueries({ queryKey: HOLIDAYS_KEY });
                        return 'deleted';
                      }}
                    />
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}

      {adding && (
        <Dialog open onOpenChange={(o) => !o && setAdding(false)}>
          <DialogContent className="max-w-sm">
            <DialogHeader><DialogTitle>Add a holiday</DialogTitle></DialogHeader>
            <form className="space-y-3" onSubmit={(ev) => { ev.preventDefault(); add.mutate(); }}>
              <Field label="Date" htmlFor="hol-date">
                <Input id="hol-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
              </Field>
              <Field label="What for" htmlFor="hol-name">
                <Input id="hol-name" value={name} placeholder="Diwali" onChange={(e) => setName(e.target.value)} required />
              </Field>
              <DialogFooter>
                <Button type="button" variant="outline" onClick={() => setAdding(false)}>Cancel</Button>
                <Button type="submit" disabled={!name.trim() || add.isPending}>Add</Button>
              </DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
      )}
    </section>
  );
}

function LeaveTypesSection({ canEdit }: { canEdit: boolean }) {
  const qc = useQueryClient();
  const rows = useQuery({ queryKey: LEAVE_KEY, queryFn: listLeaveTypes });
  const [adding, setAdding] = useState(false);
  const [code, setCode] = useState('');
  const [name, setName] = useState('');
  const [days, setDays] = useState('12');
  const [paid, setPaid] = useState(true);

  const add = useMutation({
    mutationFn: () => saveLeaveType({ code: code.toUpperCase(), name, days_per_year: Number(days), is_paid: paid, is_active: true }),
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: LEAVE_KEY });
      setAdding(false);
      setCode('');
      setName('');
      toast({ title: 'Leave kind added' });
    },
    onError: (err) => toastError(err, 'Could not add the leave kind'),
  });

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 className="text-lg font-semibold">Kinds of leave</h2>
          <p className="max-w-2xl text-sm text-muted-foreground">
            Paid leave counts as a day earned on the wage sheet; unpaid leave does not. Without a kind set against it, a
            day marked as leave is treated as unpaid.
          </p>
        </div>
        {canEdit && (
          <Button size="sm" onClick={() => setAdding(true)}>
            <Plus /> Add a kind
          </Button>
        )}
      </div>

      {rows.isLoading ? (
        <Spinner />
      ) : !rows.data?.length ? (
        <p className="text-sm text-muted-foreground">
          None set up. Most shops want two: casual leave, paid, and leave without pay.
        </p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Code</TableHead>
              <TableHead>Name</TableHead>
              <TableHead className="text-right">Days a year</TableHead>
              <TableHead>Paid</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.data.map((t) => (
              <TableRow key={t.id} className={t.is_active ? undefined : 'opacity-60'}>
                <TableCell className="font-medium">{t.code}</TableCell>
                <TableCell>{t.name}</TableCell>
                <TableCell className="text-right tabular-nums">{t.days_per_year}</TableCell>
                <TableCell>
                  <Badge variant={t.is_paid ? 'default' : 'outline'}>{t.is_paid ? 'paid' : 'unpaid'}</Badge>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}

      {adding && (
        <Dialog open onOpenChange={(o) => !o && setAdding(false)}>
          <DialogContent className="max-w-sm">
            <DialogHeader><DialogTitle>Add a kind of leave</DialogTitle></DialogHeader>
            <form className="space-y-3" onSubmit={(ev) => { ev.preventDefault(); add.mutate(); }}>
              <Field label="Code" htmlFor="lt-code" help="Short, as it appears on the register: CL, SL, LWP.">
                <Input id="lt-code" value={code} maxLength={8} onChange={(e) => setCode(e.target.value)} required />
              </Field>
              <Field label="Name" htmlFor="lt-name">
                <Input id="lt-name" value={name} placeholder="Casual leave" onChange={(e) => setName(e.target.value)} required />
              </Field>
              <Field label="Days a year" htmlFor="lt-days">
                <Input id="lt-days" type="number" min="0" step="0.5" value={days} onChange={(e) => setDays(e.target.value)} />
              </Field>
              <label className="flex items-center gap-2 text-sm">
                <Checkbox checked={paid} onChange={(e) => setPaid(e.target.checked)} />
                Paid — counts as a day earned
              </label>
              <DialogFooter>
                <Button type="button" variant="outline" onClick={() => setAdding(false)}>Cancel</Button>
                <Button type="submit" disabled={!code.trim() || !name.trim() || add.isPending}>Add</Button>
              </DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
      )}
    </section>
  );
}
