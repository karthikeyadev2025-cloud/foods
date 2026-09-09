import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Plus, Trash2 } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { searchCustomers, type CustomerRow } from '@/features/customers/api';
import { listOpenInvoices } from '@/features/invoices/api';
import { receiptModesApi } from '@/features/setup/api';
import { useDebounced } from '@/hooks/use-debounced';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, money, round, toISODate, toNumber, type Numeric } from '@/lib/format';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { getReceipt, getReceiptAllocations, getReceiptLines, listAllReceipts, listReceipts, saveReceipt } from '../api';

export function ReceiptsPage() {
  const navigate = useNavigate();
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const debounced = useDebounced(search);
  const filters = { search: debounced, from, to };
  const receipts = useQuery({ queryKey: ['receipts', 'list', { ...filters, page, pageSize }], queryFn: () => listReceipts({ ...filters, page, pageSize }), placeholderData: keepPreviousData });

  const onExport = async () => {
    try {
      const rows = await listAllReceipts(filters);
      exportToExcel('receipts', rows.map((r) => ({ 'Receipt no.': r.receipt_no, Date: dateDMY(r.receipt_date), Customer: r.customer_name, Town: r.customer_town, Modes: r.modes, Total: Number(r.total_amount ?? 0), Allocated: Number(r.allocated ?? 0), 'On account': Number(r.total_amount ?? 0) - Number(r.allocated ?? 0), Narration: r.narration })), 'Receipts');
    } catch (err) {
      toastError(err, 'Export failed');
    }
  };

  return (
    <div className="space-y-3">
      <PageHeader title="Receipts" description="Money in from customers, by mode, allocated against invoices oldest first unless you say otherwise."
        actions={<><Button variant="outline" size="sm" onClick={onExport} disabled={!receipts.data?.total}><Download /> Excel</Button>{perms.canEdit('receipts') && <Button asChild size="sm"><Link to="/receipts/new"><Plus /> New receipt</Link></Button>}</>} />
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Receipt no., customer, town…" aria-label="Search receipts" className="h-8 w-60" value={search} onChange={(ev) => { setSearch(ev.target.value); setPage(1); }} />
        <Input type="date" aria-label="From date" className="h-8 w-40" value={from} onChange={(ev) => { setFrom(ev.target.value); setPage(1); }} />
        <Input type="date" aria-label="To date" className="h-8 w-40" value={to} onChange={(ev) => { setTo(ev.target.value); setPage(1); }} />
      </div>
      {receipts.isLoading ? <Spinner /> : receipts.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load receipts: {receipts.error.message}</p>
      ) : receipts.data && receipts.data.rows.length === 0 ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No receipts match.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>No.</TableHead><TableHead>Date</TableHead><TableHead>Customer</TableHead><TableHead>Town</TableHead><TableHead>Modes</TableHead><TableHead className="text-right">Total</TableHead><TableHead className="text-right">On account</TableHead></TableRow></TableHeader>
            <TableBody>
              {receipts.data?.rows.map((r) => {
                const onAcc = round(toNumber(r.total_amount) - toNumber(r.allocated), 2);
                return (
                  <TableRow key={r.id} className="cursor-pointer" tabIndex={0} onClick={() => navigate(`/receipts/${r.id}`)} onKeyDown={(ev) => ev.key === 'Enter' && navigate(`/receipts/${r.id}`)}>
                    <TableCell className="font-medium">{r.receipt_no}</TableCell><TableCell>{dateDMY(r.receipt_date)}</TableCell><TableCell>{r.customer_name}</TableCell>
                    <TableCell className="text-muted-foreground">{r.customer_town ?? '—'}</TableCell><TableCell className="text-muted-foreground">{r.modes}</TableCell>
                    <TableCell className="num">{amount(r.total_amount)}</TableCell><TableCell className="num text-muted-foreground">{onAcc > 0 ? amount(onAcc) : '—'}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}
      {receipts.data && <Pager page={page} pageSize={pageSize} total={receipts.data.total} onPage={setPage} onPageSize={(n) => { setPageSize(n); setPage(1); }} />}
    </div>
  );
}

interface ModeLine { key: string; mode_id: string; amount: string; reference: string; cheque_date: string; bank_name: string }
let seq = 0;

export function ReceiptNewPage() {
  const perms = usePermissions();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const modes = useQuery({ queryKey: ['setup', 'receipt_modes'], queryFn: receiptModesApi.list });
  const [customer, setCustomer] = useState<CustomerRow | null>(null);
  const [date, setDate] = useState(toISODate());
  const [narration, setNarration] = useState('');
  const [lines, setLines] = useState<ModeLine[]>([]);
  const [alloc, setAlloc] = useState<Record<string, string>>({});
  const [manual, setManual] = useState(false);
  const open = useQuery({ queryKey: ['invoices', 'open', customer?.id], queryFn: () => listOpenInvoices(customer?.id ?? ''), enabled: Boolean(customer?.id) });

  useEffect(() => {
    if (modes.data && lines.length === 0) {
      const cash = modes.data.find((m) => m.is_active && m.code.toUpperCase() === 'CASH') ?? modes.data.find((m) => m.is_active);
      if (cash) setLines([{ key: `m${++seq}`, mode_id: cash.id, amount: '', reference: '', cheque_date: '', bank_name: '' }]);
    }
  }, [modes.data, lines.length]);

  const total = useMemo(() => round(lines.reduce((s, l) => s + toNumber(l.amount), 0), 2), [lines]);
  const fifo = useMemo(() => {
    const out: Record<string, number> = {};
    let rem = total;
    for (const i of open.data ?? []) {
      if (rem <= 0) break;
      const a = Math.min(rem, toNumber(i.balance));
      out[i.invoice_id ?? ''] = round(a, 2);
      rem = round(rem - a, 2);
    }
    return out;
  }, [open.data, total]);
  const allocations = manual ? Object.fromEntries(Object.entries(alloc).map(([k, v]) => [k, toNumber(v)])) : fifo;
  const allocated = round(Object.values(allocations).reduce((s, v) => s + v, 0), 2);
  const onAccount = round(total - allocated, 2);
  /**
   * What each bill still owes once this receipt is applied. The clerk is asked
   * this on the phone while the customer is still standing there, and working
   * it out in their head against a column of balances is how part-payments get
   * recorded against the wrong invoice.
   */
  const remainingOn = (invoiceId: string, balance: Numeric) => round(toNumber(balance) - (allocations[invoiceId] ?? 0), 2);
  const remainingTotal = round(
    (open.data ?? []).reduce((s, i) => s + remainingOn(i.invoice_id ?? '', i.balance), 0),
    2,
  );
  const modeOf = (id: string) => modes.data?.find((m) => m.id === id);

  const save = useMutation({
    mutationFn: async () => {
      if (!customer?.id) throw new Error('Choose a customer');
      const ls = lines.filter((l) => toNumber(l.amount) > 0);
      if (ls.length === 0) throw new Error('Enter at least one amount');
      if (onAccount < 0) throw new Error('Allocations exceed the receipt total');
      return saveReceipt(
        { customer_id: customer.id, receipt_date: date, narration: narration || null },
        ls.map((l) => ({ mode_id: l.mode_id, amount: toNumber(l.amount), reference: l.reference.trim() || null, cheque_date: l.cheque_date || null, bank_name: l.bank_name.trim() || null })),
        manual ? Object.entries(allocations).filter(([, v]) => v > 0).map(([invoice_id, v]) => ({ invoice_id, amount: v })) : [],
      );
    },
    onSuccess: async (id) => {
      await queryClient.invalidateQueries({ queryKey: ['receipts'] });
      await queryClient.invalidateQueries({ queryKey: ['invoices'] });
      await queryClient.invalidateQueries({ queryKey: ['customers'] });
      toast({ title: 'Receipt saved' });
      navigate(`/receipts/${id}`, { replace: true });
    },
    onError: (err) => toastError(err, 'Could not save the receipt'),
  });

  if (!perms.canEdit('receipts')) return <p className="text-sm text-muted-foreground">Your role cannot record receipts.</p>;

  return (
    <div className="space-y-4">
      <PageHeader title="New receipt" actions={<Button asChild variant="ghost" size="sm"><Link to="/receipts">← Receipts</Link></Button>} />
      <Card>
        <CardContent className="grid grid-cols-2 gap-3 pt-4 md:grid-cols-4">
          <Field label="Customer" htmlFor="rc-customer" className="col-span-2">
            <Combobox<CustomerRow> id="rc-customer" value={customer} onChange={(c) => { setCustomer(c); setAlloc({}); }} search={searchCustomers} queryKey="customers" getKey={(c) => c.id ?? ''} getLabel={(c) => `${c.name ?? ''}${c.town ? ` — ${c.town}` : ''}`}
              renderOption={(c) => <span><span className="font-medium">{c.name}</span><span className="text-muted-foreground">{c.town ? ` · ${c.town}` : ''} · outstanding {money(c.outstanding)}</span></span>} placeholder="Type name, mobile or town…" autoFocus eager />
          </Field>
          <Field label="Date" htmlFor="rc-date"><Input id="rc-date" type="date" value={date} onChange={(ev) => setDate(ev.target.value)} /></Field>
          <Field label="Narration" htmlFor="rc-narr"><Input id="rc-narr" value={narration} onChange={(ev) => setNarration(ev.target.value)} /></Field>
        </CardContent>
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader className="pb-2"><CardTitle className="text-base">Received by mode</CardTitle></CardHeader>
          <CardContent className="space-y-2">
            {lines.map((l) => {
              const m = modeOf(l.mode_id);
              return (
                <div key={l.key} className="grid grid-cols-[8rem_1fr_1fr_2rem] items-center gap-2">
                  <NativeSelect aria-label="Mode" className="h-8" value={l.mode_id} onChange={(ev) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, mode_id: ev.target.value } : x))}>
                    {(modes.data ?? []).filter((mm) => mm.is_active).map((mm) => <option key={mm.id} value={mm.id}>{mm.code}{mm.is_collection ? '' : ' (deduction)'}</option>)}
                  </NativeSelect>
                  <Input type="number" step="0.01" className="num h-8" aria-label={`Amount ${m?.code ?? ''}`} placeholder="Amount" value={l.amount} onChange={(ev) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, amount: ev.target.value } : x))} />
                  <Input className="h-8" aria-label={`Reference ${m?.code ?? ''}`} placeholder={m?.is_cheque ? 'Cheque no. (required)' : m?.needs_reference ? 'Reference (required)' : 'Reference'} value={l.reference} onChange={(ev) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, reference: ev.target.value } : x))} />
                  <Button type="button" variant="ghost" size="icon" aria-label="Remove line" onClick={() => setLines((p) => p.filter((x) => x.key !== l.key))}><Trash2 className="text-destructive" /></Button>
                  {m?.is_cheque && (
                    <div className="col-span-4 grid grid-cols-[8rem_1fr_1fr_2rem] items-center gap-2">
                      <span className="text-xs text-muted-foreground">cheque</span>
                      <Input type="date" className="h-8" aria-label="Cheque date" value={l.cheque_date} onChange={(ev) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, cheque_date: ev.target.value } : x))} />
                      <Input className="h-8" aria-label="Bank" placeholder="Bank" value={l.bank_name} onChange={(ev) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, bank_name: ev.target.value } : x))} />
                    </div>
                  )}
                </div>
              );
            })}
            <Button type="button" variant="outline" size="sm" onClick={() => { const m = modes.data?.find((mm) => mm.is_active); if (m) setLines((p) => [...p, { key: `m${++seq}`, mode_id: m.id, amount: '', reference: '', cheque_date: '', bank_name: '' }]); }}><Plus /> Add mode</Button>
            <div className="flex justify-between border-t pt-2 text-sm font-semibold"><span>Total</span><span className="tabular-nums">{amount(total)}</span></div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="flex items-center justify-between text-base">
              <span>Against invoices</span>
              <label className="flex items-center gap-1 text-xs font-normal"><input type="checkbox" className="accent-primary" checked={manual} onChange={(ev) => { setManual(ev.target.checked); if (ev.target.checked) setAlloc(Object.fromEntries(Object.entries(fifo).map(([k, v]) => [k, String(v)]))); }} /> Allocate manually</label>
            </CardTitle>
          </CardHeader>
          <CardContent>
            {!customer ? <p className="text-sm text-muted-foreground">Choose a customer to see open invoices.</p> : open.isLoading ? <Spinner /> : (open.data ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground">No open invoices — the full amount stays on account as an advance.</p>
            ) : (
              <Table>
                <TableHeader><TableRow><TableHead>Invoice</TableHead><TableHead>Date</TableHead><TableHead className="text-right">Balance</TableHead><TableHead className="w-32 text-right">Allocate</TableHead><TableHead className="text-right">Remaining</TableHead></TableRow></TableHeader>
                <TableBody>
                  {(open.data ?? []).map((i) => {
                    const id = i.invoice_id ?? '';
                    return (
                      <TableRow key={id}>
                        <TableCell className="font-medium">{i.invoice_no}</TableCell><TableCell>{dateDMY(i.invoice_date)}</TableCell><TableCell className="num">{amount(i.balance)}</TableCell>
                        <TableCell className="num">{manual ? <Input type="number" step="0.01" className="num h-8" aria-label={`Allocate to ${i.invoice_no}`} value={alloc[id] ?? ''} onChange={(ev) => setAlloc((p) => ({ ...p, [id]: ev.target.value }))} /> : amount(fifo[id] ?? 0)}</TableCell>
                        <TableCell className={remainingOn(id, i.balance) === 0 ? 'num text-muted-foreground' : 'num'}>{amount(remainingOn(id, i.balance))}</TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
                <TableFooter>
                  <TableRow><TableCell colSpan={3} className="text-right">Allocated</TableCell><TableCell className="num">{amount(allocated)}</TableCell><TableCell className="num font-semibold">{amount(remainingTotal)}</TableCell></TableRow>
                  <TableRow><TableCell colSpan={3} className="text-right">On account</TableCell><TableCell className={onAccount < 0 ? 'num text-destructive' : 'num'}>{amount(onAccount)}</TableCell><TableCell className="text-right text-xs font-normal text-muted-foreground">still owed</TableCell></TableRow>
                </TableFooter>
              </Table>
            )}
          </CardContent>
        </Card>
      </div>

      <div className="flex justify-end gap-2">
        <Button type="button" variant="outline" onClick={() => navigate('/receipts')}>Cancel</Button>
        <Button type="button" onClick={() => save.mutate()} disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save receipt'}</Button>
      </div>
    </div>
  );
}

export function ReceiptViewPage() {
  const { id } = useParams();
  const receipt = useQuery({ queryKey: ['receipts', 'one', id], queryFn: () => getReceipt(id ?? ''), enabled: Boolean(id) });
  const lines = useQuery({ queryKey: ['receipts', 'lines', id], queryFn: () => getReceiptLines(id ?? ''), enabled: Boolean(id) });
  const allocs = useQuery({ queryKey: ['receipts', 'allocs', id], queryFn: () => getReceiptAllocations(id ?? ''), enabled: Boolean(id) });
  if (receipt.isLoading || lines.isLoading || allocs.isLoading) return <Spinner label="Loading receipt…" />;
  if (!receipt.data) return <p role="alert" className="text-sm text-destructive">Receipt not found.</p>;
  const r = receipt.data;
  return (
    <div className="space-y-4">
      <PageHeader title={`Receipt ${r.receipt_no}`} description={`${dateDMY(r.receipt_date)} · ${r.customer_name}${r.narration ? ` · ${r.narration}` : ''}`} actions={<Button asChild variant="ghost" size="sm"><Link to="/receipts">← Receipts</Link></Button>} />
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Mode</TableHead><TableHead>Reference</TableHead><TableHead className="text-right">Amount</TableHead></TableRow></TableHeader>
            <TableBody>{(lines.data ?? []).map((l) => <TableRow key={l.id}><TableCell className="font-medium">{l.mode_code}{l.is_collection ? '' : ' (deduction)'}</TableCell><TableCell className="text-muted-foreground">{l.reference ?? '—'}</TableCell><TableCell className="num">{amount(l.amount)}</TableCell></TableRow>)}</TableBody>
            <TableFooter><TableRow><TableCell colSpan={2} className="text-right font-semibold">Total</TableCell><TableCell className="num font-semibold">{amount(r.total_amount)}</TableCell></TableRow></TableFooter>
          </Table>
        </div>
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Invoice</TableHead><TableHead>Date</TableHead><TableHead className="text-right">Allocated</TableHead></TableRow></TableHeader>
            <TableBody>
              {(allocs.data ?? []).length === 0 ? <TableRow><TableCell colSpan={3} className="text-muted-foreground">Nothing allocated — on account.</TableCell></TableRow> : (allocs.data ?? []).map((a) => <TableRow key={a.id}><TableCell className="font-medium">{a.invoice_no}</TableCell><TableCell>{dateDMY(a.invoice_date)}</TableCell><TableCell className="num">{amount(a.amount)}</TableCell></TableRow>)}
            </TableBody>
            <TableFooter><TableRow><TableCell colSpan={2} className="text-right">On account</TableCell><TableCell className="num">{amount(round(toNumber(r.total_amount) - toNumber(r.allocated), 2))}</TableCell></TableRow></TableFooter>
          </Table>
        </div>
      </div>
    </div>
  );
}
