import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, int, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { bounceCheque, chequeTone, clearCheque, depositCheque, listCashBankAccounts, listCheques, type ChequeRow, type ChequeState } from '../api';

type Action = { kind: 'deposit' | 'clear' | 'bounce' | 'cancel'; cheque: ChequeRow };

/** T7.2 — received and issued cheques: in hand → deposited → cleared / bounced, with what is due. */
export function ChequesPanel() {
  const perms = usePermissions();
  const canEdit = perms.canEdit('payments');
  const [state, setState] = useState<ChequeState | ''>('');
  const [direction, setDirection] = useState<'received' | 'issued' | ''>('');
  const [dueOnly, setDueOnly] = useState(false);
  const cheques = useQuery({ queryKey: ['accounts', 'cheques', state, direction, dueOnly], queryFn: () => listCheques({ state, direction, dueOnly }) });
  const [action, setAction] = useState<Action | null>(null);
  const rows = cheques.data ?? [];
  const due = rows.filter((c) => c.is_due).length;
  const onExport = () => exportToExcel('cheques', rows.map((c) => ({ Direction: c.direction, Party: c.party_name, 'Cheque no.': c.cheque_no, 'Cheque date': dateDMY(c.cheque_date), Bank: c.bank_name, Amount: toNumber(c.amount), State: c.state, Account: c.account_name, Deposited: c.deposited_on ? dateDMY(c.deposited_on) : '', Cleared: c.cleared_on ? dateDMY(c.cleared_on) : '', Bounced: c.bounced_on ? dateDMY(c.bounced_on) : '', Document: c.doc_no })), 'Cheques');

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <NativeSelect aria-label="Direction" className="h-8 w-36" value={direction} onChange={(e) => setDirection(e.target.value as typeof direction)}><option value="">Received & issued</option><option value="received">Received</option><option value="issued">Issued</option></NativeSelect>
        <NativeSelect aria-label="State" className="h-8 w-36" value={state} onChange={(e) => setState(e.target.value as ChequeState | '')}><option value="">All states</option>{(['in_hand', 'deposited', 'cleared', 'bounced', 'cancelled'] as ChequeState[]).map((s) => <option key={s} value={s}>{s.replace('_', ' ')}</option>)}</NativeSelect>
        <label className="flex items-center gap-1 text-sm"><Checkbox checked={dueOnly} onChange={(e) => setDueOnly(e.target.checked)} /> Due within 3 days</label>
        {due > 0 && <Badge variant="destructive">{due} due</Badge>}
        <Button size="sm" variant="outline" className="ml-auto" onClick={onExport} disabled={!rows.length}><Download /> Excel</Button>
      </div>
      <p className="text-xs text-muted-foreground">A received cheque comes from a receipt with a cheque mode; an issued one from a payment. Deposit, then mark cleared when the bank shows it. A bounce writes a reversal receipt or payment so the party owes again.</p>
      {cheques.isLoading ? <Spinner /> : cheques.error ? <p role="alert" className="text-sm text-destructive">{cheques.error.message}</p> : !rows.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No cheques.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Dir.</TableHead><TableHead>Party</TableHead><TableHead>Cheque no.</TableHead><TableHead>Cheque date</TableHead><TableHead>Bank</TableHead><TableHead className="text-right">Amount</TableHead><TableHead>State</TableHead><TableHead>Account</TableHead><TableHead>Document</TableHead><TableHead /></TableRow></TableHeader>
            <TableBody>
              {rows.map((c) => (
                <TableRow key={c.id ?? ''} className={cn(c.is_due && 'bg-amber-50/60')}>
                  <TableCell><Badge variant="outline">{c.direction}</Badge></TableCell>
                  <TableCell className="font-medium">{c.party_name}<div className="text-xs font-normal text-muted-foreground">{c.party_town}</div></TableCell>
                  <TableCell className="tabular-nums">{c.cheque_no}</TableCell>
                  <TableCell>{dateDMY(c.cheque_date)}{c.is_due && <div className="text-xs text-amber-700">{toNumber(c.days_to_date) < 0 ? `${int(-toNumber(c.days_to_date))} d overdue` : toNumber(c.days_to_date) === 0 ? 'today' : `in ${int(c.days_to_date)} d`}</div>}</TableCell>
                  <TableCell className="text-muted-foreground">{c.bank_name}</TableCell>
                  <TableCell className="num">{amount(c.amount)}</TableCell>
                  <TableCell><Badge variant={chequeTone[c.state ?? 'in_hand']}>{c.state?.replace('_', ' ')}</Badge>{c.cleared_on && <div className="text-xs text-muted-foreground">{dateDMY(c.cleared_on)}</div>}{c.bounced_on && <div className="text-xs text-muted-foreground">{dateDMY(c.bounced_on)}</div>}</TableCell>
                  <TableCell className="text-muted-foreground">{c.account_name}</TableCell>
                  <TableCell>{c.doc_no && c.ref_table === 'receipts' ? <Link to={`/receipts/${c.ref_id}`} className="text-primary hover:underline">{c.doc_no}</Link> : c.doc_no}</TableCell>
                  <TableCell className="whitespace-nowrap text-right">
                    {canEdit && c.direction === 'received' && c.state === 'in_hand' && <Button size="sm" onClick={() => setAction({ kind: 'deposit', cheque: c })}>Deposit</Button>}
                    {canEdit && ((c.direction === 'received' && c.state === 'deposited') || (c.direction === 'issued' && (c.state === 'in_hand' || c.state === 'deposited'))) && <Button size="sm" className="ml-1" onClick={() => setAction({ kind: 'clear', cheque: c })}>Cleared</Button>}
                    {canEdit && (c.state === 'in_hand' || c.state === 'deposited') && <Button size="sm" variant="ghost" className="ml-1 text-destructive" onClick={() => setAction({ kind: c.state === 'in_hand' ? 'cancel' : 'bounce', cheque: c })}>{c.state === 'in_hand' ? 'Cancel' : 'Bounced'}</Button>}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {action && <ActionDialog action={action} onClose={() => setAction(null)} />}
    </div>
  );
}

function ActionDialog({ action, onClose }: { action: Action; onClose: () => void }) {
  const qc = useQueryClient();
  const accounts = useQuery({ queryKey: ['accounts', 'cash_bank'], queryFn: listCashBankAccounts });
  const [date, setDate] = useState(toISODate());
  const [accountId, setAccountId] = useState('');
  const [charges, setCharges] = useState('0');
  const c = action.cheque;
  const banks = (accounts.data ?? []).filter((a) => a.is_active && a.kind !== 'cash');
  const run = useMutation({
    mutationFn: async () => {
      const id = c.id ?? '';
      if (action.kind === 'deposit') {
        const acc = accountId || banks[0]?.id || '';
        if (!acc) throw new Error('Add a bank account first');
        return depositCheque(id, acc, date);
      }
      if (action.kind === 'clear') return clearCheque(id, date);
      return bounceCheque(id, date, toNumber(charges), action.kind === 'cancel');
    },
    onSuccess: async () => {
      toast({ title: { deposit: 'Cheque deposited', clear: 'Cheque cleared', bounce: 'Cheque bounced — reversal recorded', cancel: 'Cheque cancelled — reversal recorded' }[action.kind] });
      await qc.invalidateQueries({ queryKey: ['accounts'] });
      await qc.invalidateQueries({ queryKey: ['receipts'] });
      await qc.invalidateQueries({ queryKey: ['payments'] });
      await qc.invalidateQueries({ queryKey: ['customers'] });
      onClose();
    },
    onError: (e) => toastError(e, 'Could not update the cheque'),
  });
  const titles = { deposit: 'Deposit cheque', clear: 'Mark cheque cleared', bounce: 'Cheque bounced', cancel: 'Cancel cheque' };
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>{titles[action.kind]}</DialogTitle>
          <DialogDescription>{c.cheque_no} · {c.party_name} · {amount(c.amount)}</DialogDescription>
        </DialogHeader>
        <form onSubmit={(ev) => { ev.preventDefault(); run.mutate(); }} className="space-y-3">
          <Field label="Date" htmlFor="ch-date"><Input id="ch-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
          {action.kind === 'deposit' && (
            <Field label="Into bank account" htmlFor="ch-acc">
              <NativeSelect id="ch-acc" value={accountId || banks[0]?.id || ''} onChange={(e) => setAccountId(e.target.value)}>{banks.map((a) => <option key={a.id ?? ''} value={a.id ?? ''}>{a.name}</option>)}</NativeSelect>
            </Field>
          )}
          {action.kind === 'bounce' && c.direction === 'received' && <Field label="Bank charges (₹)" htmlFor="ch-chg" help="Charged to Bank charges, taken from the deposit account."><Input id="ch-chg" type="number" step="0.01" className="num" value={charges} onChange={(e) => setCharges(e.target.value)} /></Field>}
          {(action.kind === 'bounce' || action.kind === 'cancel') && <p className="text-sm text-muted-foreground">{c.direction === 'received' ? 'A reversal receipt puts the amount back on the customer and reopens the bills it had paid.' : 'A reversal payment puts the amount back on the supplier / head.'}</p>}
          <DialogFooter><Button type="button" variant="outline" onClick={onClose}>Back</Button><Button type="submit" variant={action.kind === 'bounce' || action.kind === 'cancel' ? 'destructive' : 'default'} disabled={run.isPending}>{run.isPending ? 'Saving…' : titles[action.kind]}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
