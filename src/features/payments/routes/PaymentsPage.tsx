import { zodResolver } from '@hookform/resolvers/zod';
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Plus } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { z } from 'zod';
import { Field } from '@/components/Field';
import { DeleteButton } from '@/components/DeleteButton';
import { PageHeader } from '@/components/PageHeader';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { listSuppliers } from '@/features/purchases/api';
import { expenseHeadsApi, listStaff, receiptModesApi } from '@/features/setup/api';
import { useDebounced } from '@/hooks/use-debounced';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { deleteDocument } from '@/features/search/deletes';
import { amount, dateDMY, toISODate } from '@/lib/format';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { listAllPayments, listPayments, savePayment } from '../api';

const KINDS = [
  { value: 'supplier', label: 'Supplier' },
  { value: 'staff', label: 'Staff wages' },
  { value: 'expense', label: 'Expense head' },
] as const;
type Kind = (typeof KINDS)[number]['value'];

const paymentSchema = z.object({
  kind: z.enum(['supplier', 'staff', 'expense']),
  party_id: z.string().min(1, 'Choose who is being paid'),
  payment_date: z.string().min(1, 'Date is required'),
  mode_id: z.string().min(1, 'Choose how it was paid'),
  amount: z.coerce.number().positive('Amount must be greater than zero'),
  reference: z.string().trim().max(60),
  narration: z.string().trim().max(200),
  cheque_date: z.string(),
  bank_name: z.string().trim().max(80),
});
type PaymentForm = z.infer<typeof paymentSchema>;

export function PaymentsPage() {
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const [kind, setKind] = useState<Kind | ''>('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const [open, setOpen] = useState(false);
  const debounced = useDebounced(search);
  const filters = { search: debounced, kind, from, to };
  const payments = useQuery({ queryKey: ['payments', 'list', { ...filters, page, pageSize }], queryFn: () => listPayments({ ...filters, page, pageSize }), placeholderData: keepPreviousData });

  const onExport = async () => {
    try {
      const rows = await listAllPayments(filters);
      exportToExcel('payments', rows.map((r) => ({ 'Payment no.': r.payment_no, Date: dateDMY(r.payment_date), To: r.party_kind, Party: r.party_name, Mode: r.mode_code, Amount: Number(r.amount ?? 0), Reference: r.reference, Narration: r.narration })), 'Payments');
    } catch (err) {
      toastError(err, 'Export failed');
    }
  };

  return (
    <div className="space-y-3">
      <PageHeader title="Payments" description="Money out: suppliers, staff wages, and expense heads. Each one posts to the ledger."
        actions={<><Button variant="outline" size="sm" onClick={onExport} disabled={!payments.data?.total}><Download /> Excel</Button>{perms.canEdit('payments') && <Button size="sm" onClick={() => setOpen(true)}><Plus /> New payment</Button>}</>} />
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Payment no., party, narration…" aria-label="Search payments" className="h-8 w-60" value={search} onChange={(ev) => { setSearch(ev.target.value); setPage(1); }} />
        <NativeSelect aria-label="Paid to" className="h-8 w-40" value={kind} onChange={(ev) => { setKind(ev.target.value as Kind | ''); setPage(1); }}>
          <option value="">Everyone</option>
          {KINDS.map((k) => <option key={k.value} value={k.value}>{k.label}</option>)}
        </NativeSelect>
        <Input type="date" aria-label="From date" className="h-8 w-40" value={from} onChange={(ev) => { setFrom(ev.target.value); setPage(1); }} />
        <Input type="date" aria-label="To date" className="h-8 w-40" value={to} onChange={(ev) => { setTo(ev.target.value); setPage(1); }} />
      </div>
      {payments.isLoading ? <Spinner /> : payments.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load payments: {payments.error.message}</p>
      ) : payments.data && payments.data.rows.length === 0 ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No payments match.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>No.</TableHead><TableHead>Date</TableHead><TableHead>To</TableHead><TableHead>Party</TableHead><TableHead>Mode</TableHead><TableHead>Reference</TableHead><TableHead>Narration</TableHead><TableHead className="text-right">Amount</TableHead>{perms.canDelete('payments') && <TableHead className="w-10" />}</TableRow></TableHeader>
            <TableBody>
              {payments.data?.rows.map((r) => (
                <TableRow key={r.id}>
                  <TableCell className="font-medium">{r.payment_no}</TableCell><TableCell>{dateDMY(r.payment_date)}</TableCell>
                  <TableCell><Badge variant="secondary">{KINDS.find((k) => k.value === r.party_kind)?.label ?? r.party_kind}</Badge></TableCell>
                  <TableCell>{r.party_name}</TableCell><TableCell>{r.mode_code}</TableCell><TableCell className="text-muted-foreground">{r.reference ?? '—'}</TableCell><TableCell className="text-muted-foreground">{r.narration ?? '—'}</TableCell>
                  <TableCell className="num">{amount(r.amount)}</TableCell>
                {perms.canDelete('payments') && (
                    <TableCell onClick={(e) => e.stopPropagation()}>
                      <DeleteButton label={`payment ${r.payment_no}`} detail="The ledger entry is reversed, so the cash or bank balance goes back up." invalidate={['payments']} onDelete={() => deleteDocument('payment', r.id ?? '')} />
                    </TableCell>
                  )}
                  </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {payments.data && <Pager page={page} pageSize={pageSize} total={payments.data.total} onPage={setPage} onPageSize={(n) => { setPageSize(n); setPage(1); }} />}
      {open && <PaymentDialog onClose={() => setOpen(false)} />}
    </div>
  );
}

function PaymentDialog({ onClose }: { onClose: () => void }) {
  const queryClient = useQueryClient();
  const suppliers = useQuery({ queryKey: ['suppliers', 'list'], queryFn: listSuppliers });
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const heads = useQuery({ queryKey: ['setup', 'expense_heads'], queryFn: expenseHeadsApi.list });
  const modes = useQuery({ queryKey: ['setup', 'receipt_modes'], queryFn: receiptModesApi.list });
  const form = useForm<PaymentForm>({ resolver: zodResolver(paymentSchema), defaultValues: { kind: 'expense', party_id: '', payment_date: toISODate(), mode_id: '', amount: 0, reference: '', narration: '', cheque_date: '', bank_name: '' } });
  const e = form.formState.errors;
  const kind = form.watch('kind');
  const modeId = form.watch('mode_id');
  const mode = modes.data?.find((m) => m.id === modeId);
  const needsRef = mode?.needs_reference ?? false;
  const isCheque = mode?.is_cheque ?? false;

  const save = useMutation({
    mutationFn: (v: PaymentForm) =>
      savePayment({
        supplier_id: v.kind === 'supplier' ? v.party_id : null,
        staff_id: v.kind === 'staff' ? v.party_id : null,
        expense_head_id: v.kind === 'expense' ? v.party_id : null,
        payment_date: v.payment_date,
        mode_id: v.mode_id,
        amount: v.amount,
        reference: v.reference || null,
        narration: v.narration || null,
        cheque_date: v.cheque_date || null,
        bank_name: v.bank_name || null,
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['payments'] });
      await queryClient.invalidateQueries({ queryKey: ['suppliers'] });
      toast({ title: 'Payment saved' });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not save the payment'),
  });

  const parties = kind === 'supplier' ? (suppliers.data ?? []).filter((s) => s.is_active).map((s) => ({ id: s.id ?? '', label: `${s.name} · payable ${amount(s.payable)}` }))
    : kind === 'staff' ? (staff.data ?? []).filter((s) => s.is_active).map((s) => ({ id: s.id, label: s.full_name }))
    : (heads.data ?? []).filter((h) => h.is_active).map((h) => ({ id: h.id, label: h.name }));

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader><DialogTitle>New payment</DialogTitle></DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3" noValidate>
          <Field label="Paid to" htmlFor="pm-kind" error={e.kind?.message}>
            <NativeSelect id="pm-kind" {...form.register('kind', { onChange: () => form.setValue('party_id', '') })}>
              {KINDS.map((k) => <option key={k.value} value={k.value}>{k.label}</option>)}
            </NativeSelect>
          </Field>
          <Field label={KINDS.find((k) => k.value === kind)?.label ?? 'Party'} htmlFor="pm-party" error={e.party_id?.message}>
            <NativeSelect id="pm-party" {...form.register('party_id')}>
              <option value="">— choose —</option>
              {parties.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Date" htmlFor="pm-date" error={e.payment_date?.message}><Input id="pm-date" type="date" {...form.register('payment_date')} /></Field>
          <Field label="Mode" htmlFor="pm-mode" error={e.mode_id?.message}>
            <NativeSelect id="pm-mode" {...form.register('mode_id')}>
              <option value="">— choose —</option>
              {(modes.data ?? []).filter((m) => m.is_active && m.is_collection).map((m) => <option key={m.id} value={m.id}>{m.code} — {m.name}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Amount (₹)" htmlFor="pm-amount" error={e.amount?.message}><Input id="pm-amount" type="number" step="0.01" className="num" autoFocus {...form.register('amount')} /></Field>
          <Field label={isCheque ? 'Cheque no. (required)' : needsRef ? 'Reference (required)' : 'Reference'} htmlFor="pm-ref" error={e.reference?.message}><Input id="pm-ref" {...form.register('reference')} /></Field>
          {isCheque && (
            <>
              <Field label="Cheque date" htmlFor="pm-chq-date"><Input id="pm-chq-date" type="date" {...form.register('cheque_date')} /></Field>
              <Field label="Bank" htmlFor="pm-bank" help="Marked cleared later under Accounts → Cheques."><Input id="pm-bank" {...form.register('bank_name')} /></Field>
            </>
          )}
          <Field label="Narration" htmlFor="pm-narr" error={e.narration?.message} className="col-span-2"><Input id="pm-narr" {...form.register('narration')} /></Field>
          <DialogFooter className="col-span-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save payment'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
