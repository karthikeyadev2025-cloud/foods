import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { useMe } from '@/features/auth/hooks';
import { toastError } from '@/hooks/use-toast';
import { int } from '@/lib/format';
import { getOrg, masterReset, type ResetResult, type ResetScope } from '../api';

const SCOPES: { value: ResetScope; label: string; goes: string; stays: string }[] = [
  {
    value: 'transactions',
    label: 'Bills and stock only',
    goes: 'Every bill, purchase, receipt, payment, return, quotation, order, challan, batch, trip, transfer, count, cheque, ledger entry and stock movement.',
    stays: 'Products, customers, suppliers, prices, recipes and all of Setup.',
  },
  {
    value: 'masters',
    label: 'Bills, stock and the product list',
    goes: 'All of the above, and products, customers, suppliers, vehicles, routes, price lists, discount schemes, barcodes and recipes.',
    stays: 'Setup — units, pack types, sections, godowns, receipt modes, numbering.',
  },
  {
    value: 'everything',
    label: 'Everything — back to day one',
    goes: 'All of the above, and Setup itself.',
    stays: 'Only the business, the users and their logins, the permissions and the licence.',
  },
];

/** Where the shop goes next, which is different for each scope. */
const NEXT_STEP: Record<ResetScope, { say: string; cta: string; to: string }> = {
  transactions: {
    say: 'Start with the opening stock. Stock rows can be corrected for the next 30 days.',
    cta: 'Import opening stock',
    to: '/setup/import',
  },
  masters: {
    say: 'Setup is intact, but there are no products, customers or suppliers. Import them before billing.',
    cta: 'Import products',
    to: '/setup/import',
  },
  everything: {
    say: 'Setup is empty too — units, pack types, godowns. Nothing can be added until those exist, so walk through the setup again.',
    cta: 'Set up again',
    to: '/setup/wizard/units',
  },
};

/**
 * "I want to reset all data once — master reset — and start doing all fresh
 * from beginning."
 *
 * Nothing here is clever. It is deliberately slow to use: pick what goes, read
 * what stays, then type the business name. The database checks the name too, so
 * this screen cannot be the only thing standing between a busy afternoon and an
 * empty ledger.
 */
export function MasterReset() {
  const me = useMe();
  const queryClient = useQueryClient();
  const org = useQuery({ queryKey: ['setup', 'org'], queryFn: getOrg });
  const [scope, setScope] = useState<ResetScope>('transactions');
  const [typed, setTyped] = useState('');
  const [done, setDone] = useState<{ rows: ResetResult[]; scope: ResetScope } | null>(null);

  const name = (org.data?.name ?? '').trim();
  const matches = typed.trim() === name && name.length > 0;
  const chosen = SCOPES.find((s) => s.value === scope)!;

  const run = useMutation({
    mutationFn: () => masterReset(typed.trim(), scope),
    onSuccess: async (rows) => {
      // Everything on screen is now stale — the whole cache goes, not a list of
      // keys somebody has to remember to keep up to date.
      await queryClient.invalidateQueries();
      setDone({ rows, scope });
      setTyped('');
    },
    onError: (err) => toastError(err, 'The reset did not run'),
  });

  if (me.data?.role !== 'owner') return null;

  if (done) {
    const total = done.rows.reduce((s, r) => s + Number(r.rows_deleted ?? 0), 0);
    const next = NEXT_STEP[done.scope];
    return (
      <Card className="border-destructive/40">
        <CardHeader className="pb-3"><CardTitle className="text-base">Reset done</CardTitle></CardHeader>
        <CardContent className="space-y-3 text-sm">
          <p>{int(total)} rows removed across {int(done.rows.length)} tables. Document numbers start again at 1.</p>
          <div className="max-h-56 overflow-auto rounded-md border">
            <table className="w-full text-xs">
              <tbody>
                {done.rows.map((r) => (
                  <tr key={r.table_name} className="border-b last:border-0">
                    <td className="px-2 py-1">{r.table_name?.replace(/_/g, ' ')}</td>
                    <td className="num px-2 py-1">{int(r.rows_deleted)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {/*
            A reset that cleared the units and godowns leaves every Add screen
            with empty dropdowns, which reads as a broken system rather than an
            empty one. Say where to start before they find that out themselves.
          */}
          <p className="text-muted-foreground">{next.say}</p>
          <div className="flex gap-2">
            <Button asChild size="sm"><Link to={next.to}>{next.cta}</Link></Button>
            <Button variant="outline" size="sm" onClick={() => setDone(null)}>Close</Button>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="border-destructive/40">
      <CardHeader className="pb-3">
        <CardTitle className="text-base text-destructive">Master reset</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        <p className="rounded-md border border-destructive/40 bg-destructive/5 p-3">
          <span className="font-medium">This cannot be undone.</span> Take a backup from Setup → Backup first — it takes
          a few seconds and it is the only way back.
        </p>

        <label className="block space-y-1">
          <span className="text-sm font-medium">What should go?</span>
          <NativeSelect value={scope} onChange={(e) => { setScope(e.target.value as ResetScope); setTyped(''); }}>
            {SCOPES.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
          </NativeSelect>
        </label>

        <div className="rounded-md border p-3">
          <p><span className="font-medium text-destructive">Deleted:</span> {chosen.goes}</p>
          <p className="mt-1"><span className="font-medium">Kept:</span> {chosen.stays}</p>
        </div>

        <label className="block space-y-1">
          <span className="text-sm font-medium">Type <span className="font-mono">{name}</span> to confirm</span>
          <Input
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
            placeholder={name}
            aria-label="Business name to confirm the reset"
            autoComplete="off"
          />
        </label>

        <Button
          variant="destructive"
          disabled={!matches || run.isPending}
          onClick={() => run.mutate()}
        >
          {run.isPending ? 'Resetting…' : `Reset ${chosen.label.toLowerCase()}`}
        </Button>
      </CardContent>
    </Card>
  );
}
