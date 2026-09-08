import { zodResolver } from '@hookform/resolvers/zod';
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, FileCheck, Plus, Printer } from 'lucide-react';
import { useEffect, useState } from 'react';
import { useForm } from 'react-hook-form';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { z } from 'zod';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { getCustomer, searchCustomers, type CustomerRow } from '@/features/customers/api';
import { stockLocationsApi } from '@/features/setup/api';
import { useDebounced } from '@/hooks/use-debounced';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, int, qty, round, toISODate, toNumber } from '@/lib/format';
import { amountInWords } from '@/lib/money';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { invoiceLine } from '@/lib/units';
import { convertQuotation, getQuotation, getQuotationLines, listAllQuotations, listQuotations, saveQuotation, setQuotationState, nextLineKey, stateTone, type DocLine, type DocState, type QuotationRow } from '../api';
import { DocLines } from '../components/DocLines';

// ------------------------------------------------------------------ list
export function QuotationsPage() {
  const navigate = useNavigate();
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const [state, setState] = useState<DocState | ''>('');
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const debounced = useDebounced(search);
  const filters = { search: debounced, state };
  const rows = useQuery({ queryKey: ['quotations', 'list', { ...filters, page, pageSize }], queryFn: () => listQuotations({ ...filters, page, pageSize }), placeholderData: keepPreviousData });
  const onExport = async () => {
    try {
      const all = await listAllQuotations(filters);
      exportToExcel('quotations', all.map((r) => ({ 'Quote no.': r.quote_no, Date: dateDMY(r.quote_date), 'Valid till': r.valid_till ? dateDMY(r.valid_till) : '', Customer: r.customer_name, Town: r.customer_town, State: r.state, Boxes: toNumber(r.total_boxes), Total: toNumber(r.total), Invoice: r.invoice_no })), 'Quotations');
    } catch (e) {
      toastError(e, 'Export failed');
    }
  };
  return (
    <div className="space-y-3">
      <PageHeader title="Quotations" description="The client's starting form. Same grid as the invoice; convert in one click and nothing is re-typed."
        actions={<><Button variant="outline" size="sm" onClick={onExport} disabled={!rows.data?.total}><Download /> Excel</Button>{perms.canEdit('invoices') && <Button asChild size="sm"><Link to="/quotations/new"><Plus /> New quotation</Link></Button>}</>} />
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Quote no., customer, town…" aria-label="Search" className="h-8 w-60" value={search} onChange={(e) => { setSearch(e.target.value); setPage(1); }} />
        <NativeSelect aria-label="State" className="h-8 w-36" value={state} onChange={(e) => { setState(e.target.value as DocState | ''); setPage(1); }}><option value="">All states</option><option value="open">Open</option><option value="converted">Converted</option><option value="cancelled">Cancelled</option></NativeSelect>
      </div>
      {rows.isLoading ? <Spinner /> : rows.error ? <p role="alert" className="text-sm text-destructive">{rows.error.message}</p> : !rows.data?.rows.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No quotations.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>No.</TableHead><TableHead>Date</TableHead><TableHead>Valid till</TableHead><TableHead>Customer</TableHead><TableHead>Town</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead className="text-right">Total</TableHead><TableHead>State</TableHead></TableRow></TableHeader>
            <TableBody>
              {rows.data.rows.map((r) => (
                <TableRow key={r.id ?? ''} className="cursor-pointer" tabIndex={0} onClick={() => navigate(`/quotations/${r.id}`)} onKeyDown={(ev) => ev.key === 'Enter' && navigate(`/quotations/${r.id}`)}>
                  <TableCell className="font-medium">{r.quote_no}</TableCell><TableCell>{dateDMY(r.quote_date)}</TableCell>
                  <TableCell className={r.is_expired ? 'text-destructive' : ''}>{r.valid_till ? dateDMY(r.valid_till) : '—'}{r.is_expired && ' (expired)'}</TableCell>
                  <TableCell>{r.customer_name}</TableCell><TableCell className="text-muted-foreground">{r.customer_town}</TableCell>
                  <TableCell className="num">{qty(r.total_boxes)}</TableCell><TableCell className="num">{amount(r.total)}</TableCell>
                  <TableCell><Badge variant={stateTone[r.state ?? 'open']}>{r.state}</Badge>{r.invoice_no && <div className="text-xs text-muted-foreground">{r.invoice_no}</div>}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {rows.data && <Pager page={page} pageSize={pageSize} total={rows.data.total} onPage={setPage} onPageSize={(n) => { setPageSize(n); setPage(1); }} />}
    </div>
  );
}

// ------------------------------------------------------------------ edit
const headerSchema = z.object({
  customer_id: z.string().min(1, 'Choose a customer'),
  quote_date: z.string().min(1, 'Date is required'),
  valid_till: z.string(),
  transport_name: z.string().trim().max(80),
  lr_no: z.string().trim().max(40),
  lr_date: z.string(),
  freight: z.coerce.number().min(0),
  discount: z.coerce.number().min(0),
  round_off: z.coerce.number(),
  notes: z.string().trim().max(500),
});
type HeaderForm = z.infer<typeof headerSchema>;

export function QuotationEditPage() {
  const { id } = useParams();
  const isNew = !id || id === 'new';
  const quote = useQuery({ queryKey: ['quotations', 'one', id], queryFn: () => getQuotation(id ?? ''), enabled: !isNew });
  const lines = useQuery({ queryKey: ['quotations', 'lines', id], queryFn: () => getQuotationLines(id ?? ''), enabled: !isNew });
  if (!isNew && (quote.isLoading || lines.isLoading)) return <Spinner />;
  if (!isNew && (!quote.data || !lines.data)) return <p role="alert" className="text-sm text-destructive">Quotation not found.</p>;
  return (
    <div className="space-y-4">
      <PageHeader title={isNew ? 'New quotation' : `Quotation ${quote.data?.quote_no}`} actions={<Button asChild variant="ghost" size="sm"><Link to="/quotations">← Quotations</Link></Button>} />
      <QuotationEditor key={`${quote.data?.id ?? 'new'}-${quote.data?.state ?? ''}`} quote={quote.data ?? undefined} initialLines={(lines.data ?? []).map((l) => ({ key: nextLineKey(), item_id: l.item_id ?? '', item_code: l.item_code ?? '', item_name: l.item_name ?? '', units_per_box: toNumber(l.units_per_box), boxes: toNumber(l.boxes), rate: toNumber(l.rate) }))} />
    </div>
  );
}

function QuotationEditor({ quote, initialLines }: { quote?: QuotationRow; initialLines: DocLine[] }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const perms = usePermissions();
  const editable = perms.canEdit('invoices') && (!quote || quote.state === 'open');
  const form = useForm<HeaderForm>({ resolver: zodResolver(headerSchema), defaultValues: { customer_id: quote?.customer_id ?? '', quote_date: quote?.quote_date ?? toISODate(), valid_till: quote?.valid_till ?? '', transport_name: quote?.transport_name ?? '', lr_no: quote?.lr_no ?? '', lr_date: quote?.lr_date ?? '', freight: toNumber(quote?.freight), discount: toNumber(quote?.discount), round_off: toNumber(quote?.round_off), notes: quote?.notes ?? '' } });
  const { register, setValue, watch, formState: { errors: e } } = form;
  const [customer, setCustomer] = useState<CustomerRow | null>(null);
  useEffect(() => { if (quote?.customer_id && !customer) getCustomer(quote.customer_id).then(setCustomer).catch(() => undefined); }, [quote?.customer_id, customer]);
  const [lines, setLines] = useState<DocLine[]>(initialLines);
  const [converting, setConverting] = useState(false);
  const subtotal = round(lines.reduce((s, l) => s + invoiceLine({ boxes: l.boxes, rate: l.rate, unitsPerBox: l.units_per_box }).total, 0), 2);
  const net = round(subtotal - toNumber(watch('discount')) + toNumber(watch('freight')) + toNumber(watch('round_off')), 2);
  const invalidate = () => qc.invalidateQueries({ queryKey: ['quotations'] });

  const save = useMutation({
    mutationFn: async (h: HeaderForm) => {
      if (!lines.length) throw new Error('Add at least one line');
      return saveQuotation({ id: quote?.id ?? undefined, customer_id: h.customer_id, quote_date: h.quote_date, valid_till: h.valid_till || null, transport_name: h.transport_name || null, lr_no: h.lr_no || null, lr_date: h.lr_date || null, freight: h.freight, discount: h.discount, round_off: h.round_off, notes: h.notes || null }, lines.map((l) => ({ item_id: l.item_id, boxes: l.boxes, rate: l.rate })));
    },
    onSuccess: async (newId) => { await invalidate(); toast({ title: 'Quotation saved' }); navigate(`/quotations/${newId}`, { replace: true }); },
    onError: (err) => toastError(err, 'Could not save'),
  });
  const cancel = useMutation({
    mutationFn: (s: 'open' | 'cancelled') => setQuotationState(quote?.id ?? '', s),
    onSuccess: async (_d, s) => { await invalidate(); toast({ title: `Quotation ${s}` }); },
    onError: (err) => toastError(err, 'Could not change state'),
  });

  return (
    <div className="space-y-4">
      {quote && (
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={stateTone[quote.state ?? 'open']}>{quote.state}</Badge>
          <span className="text-sm text-muted-foreground">{dateDMY(quote.quote_date)}{quote.valid_till ? ` · valid till ${dateDMY(quote.valid_till)}` : ''}{quote.invoice_no ? <> · became <Link to={`/invoices/${quote.invoice_id}`} className="text-primary hover:underline">{quote.invoice_no}</Link></> : null}</span>
          <span className="ml-auto flex flex-wrap gap-2">
            <Button asChild variant="outline" size="sm"><Link to={`/quotations/${quote.id}/print`}><Printer /> Print</Link></Button>
            {perms.canEdit('invoices') && quote.state === 'open' && <Button size="sm" onClick={() => setConverting(true)}><FileCheck /> Convert to invoice</Button>}
            {perms.canEdit('invoices') && quote.state === 'open' && <Button size="sm" variant="ghost" className="text-destructive" onClick={() => cancel.mutate('cancelled')} disabled={cancel.isPending}>Cancel quotation</Button>}
            {perms.canEdit('invoices') && quote.state === 'cancelled' && <Button size="sm" variant="outline" onClick={() => cancel.mutate('open')} disabled={cancel.isPending}>Reopen</Button>}
          </span>
        </div>
      )}
      <form onSubmit={(ev) => ev.preventDefault()} noValidate className="space-y-4">
        <Card>
          <CardContent className="grid grid-cols-2 gap-3 pt-4 md:grid-cols-4">
            <Field label="Customer" htmlFor="qt-customer" error={e.customer_id?.message} className="col-span-2">
              <Combobox<CustomerRow> id="qt-customer" value={customer} onChange={(c) => { setCustomer(c); setValue('customer_id', c?.id ?? '', { shouldValidate: true }); }} search={searchCustomers} queryKey="customers" getKey={(c) => c.id ?? ''} getLabel={(c) => `${c.name ?? ''}${c.town ? ` — ${c.town}` : ''}`} renderOption={(c) => <span><span className="font-medium">{c.name}</span><span className="text-muted-foreground">{c.town ? ` · ${c.town}` : ''}</span></span>} placeholder="Type name, mobile or town…" autoFocus={!quote} disabled={!editable} eager />
            </Field>
            <Field label="Quotation date" htmlFor="qt-date" error={e.quote_date?.message}><Input id="qt-date" type="date" disabled={!editable} {...register('quote_date')} /></Field>
            <Field label="Valid till" htmlFor="qt-valid"><Input id="qt-valid" type="date" disabled={!editable} {...register('valid_till')} /></Field>
            <Field label="Transport name" htmlFor="qt-transport"><Input id="qt-transport" disabled={!editable} {...register('transport_name')} /></Field>
            <Field label="L.R. no." htmlFor="qt-lr"><Input id="qt-lr" disabled={!editable} {...register('lr_no')} /></Field>
            <Field label="L.R. date" htmlFor="qt-lrdate"><Input id="qt-lrdate" type="date" disabled={!editable} {...register('lr_date')} /></Field>
            <Field label="Freight (₹)" htmlFor="qt-freight" error={e.freight?.message}><Input id="qt-freight" type="number" step="0.01" className="num" disabled={!editable} {...register('freight')} /></Field>
          </CardContent>
        </Card>
        <DocLines lines={lines} onChange={setLines} editable={editable} customerId={customer?.id} date={watch('quote_date')} />
        <div className="grid gap-4 md:grid-cols-[1fr_20rem]">
          <Card><CardContent className="grid grid-cols-2 gap-3 pt-4">
            <Field label="Notes" htmlFor="qt-notes" className="col-span-2"><Input id="qt-notes" disabled={!editable} {...register('notes')} /></Field>
            <Field label="Discount (₹)" htmlFor="qt-discount" error={e.discount?.message}><Input id="qt-discount" type="number" step="0.01" className="num" disabled={!editable} {...register('discount')} /></Field>
            <Field label="Round off (₹)" htmlFor="qt-round"><Input id="qt-round" type="number" step="0.01" className="num" disabled={!editable} {...register('round_off')} /></Field>
          </CardContent></Card>
          <Card className="bg-secondary/40"><CardContent className="space-y-1 pt-4 text-sm">
            <div className="flex justify-between"><span className="text-muted-foreground">Subtotal</span><span className="tabular-nums">{amount(subtotal)}</span></div>
            <div className="flex items-baseline justify-between border-t pt-1 text-base font-semibold"><span>Net Amount</span><span className="tabular-nums">{amount(net)}</span></div>
            <p className="text-xs text-muted-foreground">{amountInWords(net)}</p>
          </CardContent></Card>
        </div>
        {editable && <div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={() => navigate('/quotations')}>Back</Button><Button type="button" disabled={save.isPending} onClick={form.handleSubmit((h) => save.mutate(h))}>{save.isPending ? 'Saving…' : 'Save quotation'}</Button></div>}
      </form>
      {quote && converting && <ConvertDialog quote={quote} onClose={() => setConverting(false)} />}
    </div>
  );
}

function ConvertDialog({ quote, onClose }: { quote: QuotationRow; onClose: () => void }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const [locationId, setLocationId] = useState('');
  const [date, setDate] = useState(toISODate());
  const loc = locationId || locations.data?.find((l) => l.is_active && l.kind === 'godown')?.id || locations.data?.[0]?.id || '';
  const convert = useMutation({
    mutationFn: () => convertQuotation(quote.id ?? '', loc, date),
    onSuccess: async (invId) => { await qc.invalidateQueries({ queryKey: ['quotations'] }); await qc.invalidateQueries({ queryKey: ['invoices'] }); toast({ title: 'Draft invoice created from the quotation' }); navigate(`/invoices/${invId}`); },
    onError: (err) => toastError(err, 'Could not convert'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogHeader><DialogTitle>Convert {quote.quote_no} to an invoice</DialogTitle><DialogDescription>Every line, the transport block and the freight go across as they are. The invoice opens as a draft for you to confirm.</DialogDescription></DialogHeader>
        <Field label="Stock leaves from" htmlFor="cv-loc"><NativeSelect id="cv-loc" value={loc} onChange={(e) => setLocationId(e.target.value)}>{(locations.data ?? []).filter((l) => l.is_active).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</NativeSelect></Field>
        <Field label="Invoice date" htmlFor="cv-date"><Input id="cv-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
        <DialogFooter><Button variant="outline" onClick={onClose}>Back</Button><Button onClick={() => convert.mutate()} disabled={convert.isPending || !loc}>{convert.isPending ? 'Converting…' : 'Create invoice'}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ------------------------------------------------------------------ print
export function QuotationPrintPage() {
  const { id } = useParams();
  const me = useMe();
  const quote = useQuery({ queryKey: ['quotations', 'one', id], queryFn: () => getQuotation(id ?? ''), enabled: Boolean(id) });
  const lines = useQuery({ queryKey: ['quotations', 'lines', id], queryFn: () => getQuotationLines(id ?? ''), enabled: Boolean(id) });
  const customer = useQuery({ queryKey: ['customers', 'one', quote.data?.customer_id], queryFn: () => getCustomer(quote.data?.customer_id ?? ''), enabled: Boolean(quote.data?.customer_id) });
  useEffect(() => { document.title = quote.data ? `Quotation ${quote.data.quote_no}` : 'Quotation'; }, [quote.data]);
  if (quote.isLoading || lines.isLoading || me.isLoading) return <Spinner label="Preparing print…" full />;
  if (!quote.data || !lines.data) return <p className="p-6 text-sm text-destructive">Quotation not found.</p>;
  const q = quote.data;
  const org = me.data;
  const totalBoxes = lines.data.reduce((s, l) => s + toNumber(l.boxes), 0);
  const totalQty = lines.data.reduce((s, l) => s + toNumber(l.qty), 0);
  const phones = [customer.data?.mobile1, customer.data?.mobile2, customer.data?.mobile3].filter(Boolean).join(',');
  return (
    <div className="min-h-screen bg-neutral-200 print:bg-white">
      <div className="no-print flex items-center justify-between gap-2 border-b bg-card px-4 py-2 text-sm">
        <Button asChild variant="ghost" size="sm"><Link to={`/quotations/${q.id}`}>← Back to quotation</Link></Button>
        <Button size="sm" onClick={() => window.print()}>Print</Button>
      </div>
      <div className="print-sheet mx-auto my-4 bg-white p-8 text-[12px] leading-tight text-black print:my-0 print:p-6">
        <div className="text-center text-base font-bold tracking-wide">QUOTATION</div>
        <div className="text-center text-xs text-neutral-700">{org?.org_name ?? 'JYOTHI FOODS'}{org?.address ? ` · ${org.address}` : ''}{org?.org_phone ? ` · Ph ${org.org_phone}` : ''}{org?.fssai_no ? ` · FSSAI ${org.fssai_no}` : ''}</div>
        <div className="mt-2 grid grid-cols-2 border border-black">
          <div className="border-r border-black p-2"><div className="font-bold">{q.customer_name}</div><div>{q.customer_town}</div>{phones && <div>PH NO : {phones}</div>}</div>
          <div className="p-2">
            <div className="flex justify-between"><span className="font-bold">Date</span><span>{dateDMY(q.quote_date)}</span></div>
            <div className="flex justify-between"><span className="font-bold">Quotation No.</span><span>{q.quote_no}</span></div>
            <div className="flex justify-between"><span>Valid till</span><span>{q.valid_till ? dateDMY(q.valid_till) : ''}</span></div>
            <div className="flex justify-between"><span>Transport Name</span><span>{q.transport_name ?? ''}</span></div>
            <div className="flex justify-between"><span>L.R No.</span><span>{q.lr_no ?? ''}</span></div>
            <div className="flex justify-between"><span>Freight</span><span>{toNumber(q.freight) ? amount(q.freight) : ''}</span></div>
          </div>
        </div>
        <table className="mt-2 w-full border-collapse border border-black">
          <thead><tr className="border-b border-black"><th className="w-10 border-r border-black p-1 text-left">S.No</th><th className="w-16 border-r border-black p-1 text-left">CODE</th><th className="border-r border-black p-1 text-left">Item Name</th><th className="w-16 border-r border-black p-1 text-right">Jars</th><th className="w-16 border-r border-black p-1 text-right">Boxes</th><th className="w-16 border-r border-black p-1 text-right">Qty</th><th className="w-16 border-r border-black p-1 text-right">Rate</th><th className="w-24 p-1 text-right">Total</th></tr></thead>
          <tbody>
            {lines.data.map((l, i) => <tr key={l.id ?? i}><td className="border-r border-black px-1 text-center">{i + 1}</td><td className="border-r border-black px-1">{l.item_code}</td><td className="border-r border-black px-1">{l.item_name}</td><td className="border-r border-black px-1 text-right tabular-nums">{qty(l.units_per_box)}</td><td className="border-r border-black px-1 text-right tabular-nums">{qty(l.boxes)}</td><td className="border-r border-black px-1 text-right tabular-nums">{qty(l.qty)}</td><td className="border-r border-black px-1 text-right tabular-nums">{amount(l.rate)}</td><td className="px-1 text-right tabular-nums">{amount(l.amount)}</td></tr>)}
            {Array.from({ length: Math.max(0, 18 - lines.data.length) }).map((_, i) => <tr key={`pad-${i}`} className="h-4"><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td /></tr>)}
          </tbody>
          <tfoot><tr className="border-t border-black font-bold"><td colSpan={4} className="border-r border-black px-1 text-right">Total:</td><td className="border-r border-black px-1 text-right tabular-nums">{qty(totalBoxes)}</td><td className="border-r border-black px-1 text-right tabular-nums">{int(totalQty)}</td><td className="border-r border-black" /><td /></tr></tfoot>
        </table>
        <div className="mt-1 grid grid-cols-[1fr_auto] border border-black">
          <div className="border-r border-black p-1"><div className="font-bold">Total amount in words :</div><div>{amountInWords(toNumber(q.total))}</div></div>
          <div className="p-1 text-right">{toNumber(q.discount) > 0 && <div>Discount : {amount(q.discount)}</div>}{toNumber(q.freight) > 0 && <div>Freight : {amount(q.freight)}</div>}{toNumber(q.round_off) !== 0 && <div>Round off : {amount(q.round_off)}</div>}<div className="text-sm font-bold">Net Amount : <span className="ml-4 tabular-nums">{amount(q.total)}</span></div></div>
        </div>
        <div className="mt-1 flex justify-between border border-black p-1"><span className="font-bold">E&amp;E.O</span><span>For {org?.org_name ?? 'JYOTHI FOODS'}</span></div>
        <ol className="mt-2 list-decimal space-y-0.5 pl-5">
          <li className="font-bold uppercase">Damage or breakage only {int(org?.breakage_recovery_pct ?? 0)}% recovery.</li>
          <li>Interest at {int(org?.interest_pct_pa ?? 0)}% will be charged from the date of the bill if not paid within {int(org?.credit_days ?? 0)} days.</li>
          <li>Subject to {org?.jurisdiction ?? ''} jurisdiction only.</li>
        </ol>
        <div className="mt-8 flex items-end justify-between"><div className="text-center font-bold">THANKING YOU FOR SHOPPING &amp; VISIT AGAIN</div><div>Authorised Signatory.</div></div>
      </div>
      <style>{`.print-sheet { width: 210mm; min-height: 297mm; } @page { size: A4; margin: 10mm; } @media print { .print-sheet { width: auto; min-height: 0; box-shadow: none; } body { background: white; } }`}</style>
    </div>
  );
}
