import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowLeftRight, Download, Pencil, Plus } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { z } from 'zod';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, money, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { accountBook, cashBankApi, listCashBankAccounts, saveTransfer, type CashBankAccountRow } from '../api';

const accountSchema = z.object({
  name: z.string().trim().min(1, 'Name is required').max(80),
  kind: z.enum(['cash', 'bank', 'wallet']),
  bank_name: z.string().trim().max(80),
  account_last4: z.string().trim().max(4),
  ifsc: z.string().trim().max(11),
  opening_balance: z.coerce.number(),
  as_on: z.string(),
  is_active: z.boolean(),
});
type AccountForm = z.infer<typeof accountSchema>;

const transferSchema = z.object({
  from_account: z.string().min(1, 'From which account?'),
  to_account: z.string().min(1, 'To which account?'),
  amount: z.coerce.number().positive('Amount must be above zero'),
  txn_date: z.string().min(1),
  narration: z.string().trim().max(200),
});
type TransferForm = z.infer<typeof transferSchema>;

/** T7.1 — accounts with live balances, the cash book / bank book per account, transfers. */
export function CashBankPanel() {
  const perms = usePermissions();
  const canEdit = perms.canEdit('payments');
  const accounts = useQuery({ queryKey: ['accounts', 'cash_bank'], queryFn: listCashBankAccounts });
  const [selected, setSelected] = useState<string>('');
  const [editing, setEditing] = useState<{ row: CashBankAccountRow | null } | null>(null);
  const [transferring, setTransferring] = useState(false);
  const rows = accounts.data ?? [];
  const current = rows.find((a) => a.id === selected) ?? rows[0] ?? null;
  const total = rows.filter((a) => a.is_active).reduce((s, a) => s + toNumber(a.balance), 0);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <p className="text-sm text-muted-foreground">Every receipt, payment, cheque and transfer lands in one of these. Balances are the sum of those movements plus the opening figure.</p>
        <span className="ml-auto flex gap-2">
          {canEdit && <Button size="sm" variant="outline" onClick={() => setTransferring(true)} disabled={rows.length < 2}><ArrowLeftRight /> Transfer</Button>}
          {canEdit && <Button size="sm" onClick={() => setEditing({ row: null })}><Plus /> Account</Button>}
        </span>
      </div>
      {accounts.isLoading ? <Spinner /> : accounts.error ? (
        <p role="alert" className="text-sm text-destructive">{accounts.error.message}</p>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {rows.map((a) => (
            <button key={a.id ?? ''} type="button" onClick={() => setSelected(a.id ?? '')} className="text-left">
              <Card className={cn('h-full transition-colors hover:border-primary/60', current?.id === a.id && 'border-primary', !a.is_active && 'opacity-60')}>
                <CardContent className="p-4">
                  <div className="flex items-center justify-between text-xs uppercase tracking-wide text-muted-foreground"><span>{a.kind}</span>{Number(a.cheques_pending ?? 0) > 0 && <Badge variant="secondary">{a.cheques_pending} cheque{Number(a.cheques_pending) === 1 ? '' : 's'} pending</Badge>}</div>
                  <div className="mt-1 font-medium">{a.name}{a.bank_name ? <span className="text-xs font-normal text-muted-foreground"> · {a.bank_name}{a.account_last4 ? ` ····${a.account_last4}` : ''}</span> : null}</div>
                  <div className={cn('text-2xl font-semibold tabular-nums', toNumber(a.balance) < 0 && 'text-destructive')}>{money(a.balance)}</div>
                  <div className="text-xs text-muted-foreground">{a.last_txn_date ? `last movement ${dateDMY(a.last_txn_date)}` : 'no movements yet'}</div>
                </CardContent>
              </Card>
            </button>
          ))}
          <Card className="h-full border-dashed"><CardContent className="p-4"><div className="text-xs uppercase tracking-wide text-muted-foreground">All accounts</div><div className="mt-1 text-2xl font-semibold tabular-nums">{money(total)}</div><div className="text-xs text-muted-foreground">{rows.filter((a) => a.is_active).length} active</div></CardContent></Card>
        </div>
      )}
      {current && <AccountBook account={current} canEdit={canEdit} onEdit={() => setEditing({ row: current })} />}
      {editing && <AccountDialog row={editing.row} onClose={() => setEditing(null)} />}
      {transferring && <TransferDialog accounts={rows} onClose={() => setTransferring(false)} />}
    </div>
  );
}

function AccountBook({ account, canEdit, onEdit }: { account: CashBankAccountRow; canEdit: boolean; onEdit: () => void }) {
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const book = useQuery({ queryKey: ['accounts', 'book', account.id, from, to], queryFn: () => accountBook(account.id ?? '', from, to) });
  const rows = book.data ?? [];
  const onExport = () => exportToExcel(`${account.kind}-book-${account.name}`, rows.map((r) => ({ Date: r.txn_date ? dateDMY(r.txn_date) : '', Document: r.doc, 'No.': r.doc_no ?? '', Party: r.party ?? '', Narration: r.narration ?? '', In: toNumber(r.money_in), Out: toNumber(r.money_out), Balance: toNumber(r.balance) })), `${account.kind} book`);
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-end gap-2">
        <h3 className="text-base font-semibold">{account.kind === 'cash' ? 'Cash book' : 'Bank book'} — {account.name}</h3>
        {canEdit && <Button size="sm" variant="ghost" aria-label="Edit account" onClick={onEdit}><Pencil /></Button>}
        <span className="ml-auto flex items-end gap-2">
          <Field label="From" htmlFor="bk-from"><Input id="bk-from" type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
          <Field label="To" htmlFor="bk-to"><Input id="bk-to" type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
          <Button size="sm" variant="outline" onClick={onExport} disabled={!rows.length}><Download /> Excel</Button>
        </span>
      </div>
      {book.isLoading ? <Spinner /> : book.error ? <p role="alert" className="text-sm text-destructive">{book.error.message}</p> : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead className="w-28">Date</TableHead><TableHead className="w-24">Document</TableHead><TableHead className="w-28">No.</TableHead><TableHead>Party / narration</TableHead><TableHead className="text-right">In</TableHead><TableHead className="text-right">Out</TableHead><TableHead className="text-right">Balance</TableHead></TableRow></TableHeader>
            <TableBody>
              {rows.map((r, i) => (
                <TableRow key={r.txn_id ?? `o${i}`} className={cn(r.doc === 'Opening' && 'bg-muted/40')}>
                  <TableCell>{r.txn_date ? dateDMY(r.txn_date) : ''}</TableCell>
                  <TableCell>{r.doc}</TableCell>
                  <TableCell className="font-medium">{r.doc_no}</TableCell>
                  <TableCell>{r.party}{r.party && r.narration ? ' — ' : ''}<span className="text-muted-foreground">{r.narration}</span></TableCell>
                  <TableCell className="num">{toNumber(r.money_in) ? amount(r.money_in) : ''}</TableCell>
                  <TableCell className="num">{toNumber(r.money_out) ? amount(r.money_out) : ''}</TableCell>
                  <TableCell className={cn('num font-medium', toNumber(r.balance) < 0 && 'text-destructive')}>{amount(r.balance)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow><TableCell colSpan={4} className="text-right">Period</TableCell><TableCell className="num">{amount(rows.filter((r) => r.doc !== 'Opening').reduce((s, r) => s + toNumber(r.money_in), 0))}</TableCell><TableCell className="num">{amount(rows.filter((r) => r.doc !== 'Opening').reduce((s, r) => s + toNumber(r.money_out), 0))}</TableCell><TableCell className="num">{amount(rows[rows.length - 1]?.balance)}</TableCell></TableRow>
            </TableFooter>
          </Table>
        </div>
      )}
    </div>
  );
}

function AccountDialog({ row, onClose }: { row: CashBankAccountRow | null; onClose: () => void }) {
  const qc = useQueryClient();
  const form = useForm<AccountForm>({
    resolver: zodResolver(accountSchema),
    defaultValues: row
      ? { name: row.name ?? '', kind: row.kind ?? 'bank', bank_name: row.bank_name ?? '', account_last4: row.account_last4 ?? '', ifsc: row.ifsc ?? '', opening_balance: toNumber(row.opening_balance), as_on: row.as_on ?? '', is_active: row.is_active ?? true }
      : { name: '', kind: 'bank', bank_name: '', account_last4: '', ifsc: '', opening_balance: 0, as_on: toISODate(), is_active: true },
  });
  const save = useMutation({
    mutationFn: (v: AccountForm) => {
      const values = { name: v.name, kind: v.kind, bank_name: v.bank_name || null, account_last4: v.account_last4 || null, ifsc: v.ifsc || null, opening_balance: v.opening_balance, as_on: v.as_on || null, is_active: v.is_active };
      return row?.id ? cashBankApi.update(row.id, values) : cashBankApi.create(values);
    },
    onSuccess: async () => { toast({ title: 'Account saved' }); await qc.invalidateQueries({ queryKey: ['accounts'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not save'),
  });
  const e = form.formState.errors;
  const kind = form.watch('kind');
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>{row ? 'Edit account' : 'New cash / bank account'}</DialogTitle></DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3">
          <Field label="Name" htmlFor="ac-name" className="col-span-2" error={e.name?.message}><Input id="ac-name" autoFocus placeholder="SBI current / Cash counter" {...form.register('name')} /></Field>
          <Field label="Kind" htmlFor="ac-kind"><NativeSelect id="ac-kind" {...form.register('kind')}><option value="cash">Cash</option><option value="bank">Bank</option><option value="wallet">Wallet / UPI</option></NativeSelect></Field>
          <Field label="Opening balance (₹)" htmlFor="ac-ob" error={e.opening_balance?.message}><Input id="ac-ob" type="number" step="0.01" className="num" {...form.register('opening_balance')} /></Field>
          {kind !== 'cash' && (
            <>
              <Field label="Bank" htmlFor="ac-bank"><Input id="ac-bank" {...form.register('bank_name')} /></Field>
              <Field label="Account last 4" htmlFor="ac-last4" help="Never the full number." error={e.account_last4?.message}><Input id="ac-last4" maxLength={4} {...form.register('account_last4')} /></Field>
              <Field label="IFSC" htmlFor="ac-ifsc" error={e.ifsc?.message}><Input id="ac-ifsc" {...form.register('ifsc')} /></Field>
            </>
          )}
          <Field label="Opening as on" htmlFor="ac-ason"><Input id="ac-ason" type="date" {...form.register('as_on')} /></Field>
          <label className="col-span-2 flex items-center gap-2 text-sm"><Checkbox {...form.register('is_active')} /> Active</label>
          <DialogFooter className="col-span-2 pt-2"><Button type="button" variant="outline" onClick={onClose}>Cancel</Button><Button type="submit" disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save'}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function TransferDialog({ accounts, onClose }: { accounts: CashBankAccountRow[]; onClose: () => void }) {
  const qc = useQueryClient();
  const cash = accounts.find((a) => a.kind === 'cash');
  const bank = accounts.find((a) => a.kind !== 'cash');
  const form = useForm<TransferForm>({ resolver: zodResolver(transferSchema), defaultValues: { from_account: cash?.id ?? '', to_account: bank?.id ?? '', amount: 0, txn_date: toISODate(), narration: '' } });
  const save = useMutation({
    mutationFn: (v: TransferForm) => saveTransfer({ ...v, narration: v.narration || null }),
    onSuccess: async () => { toast({ title: 'Transfer recorded' }); await qc.invalidateQueries({ queryKey: ['accounts'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not transfer'),
  });
  const e = form.formState.errors;
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>Transfer between accounts</DialogTitle></DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3">
          <Field label="From" htmlFor="tr-from" error={e.from_account?.message}><NativeSelect id="tr-from" {...form.register('from_account')}>{accounts.filter((a) => a.is_active).map((a) => <option key={a.id ?? ''} value={a.id ?? ''}>{a.name} ({amount(a.balance)})</option>)}</NativeSelect></Field>
          <Field label="To" htmlFor="tr-to" error={e.to_account?.message}><NativeSelect id="tr-to" {...form.register('to_account')}>{accounts.filter((a) => a.is_active).map((a) => <option key={a.id ?? ''} value={a.id ?? ''}>{a.name}</option>)}</NativeSelect></Field>
          <Field label="Amount (₹)" htmlFor="tr-amt" error={e.amount?.message}><Input id="tr-amt" type="number" step="0.01" className="num" autoFocus {...form.register('amount')} /></Field>
          <Field label="Date" htmlFor="tr-date"><Input id="tr-date" type="date" {...form.register('txn_date')} /></Field>
          <Field label="Narration" htmlFor="tr-narr" className="col-span-2"><Input id="tr-narr" placeholder="Cash deposited at branch" {...form.register('narration')} /></Field>
          <DialogFooter className="col-span-2 pt-2"><Button type="button" variant="outline" onClick={onClose}>Cancel</Button><Button type="submit" disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Transfer'}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
