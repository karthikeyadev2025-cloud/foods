import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Plus, Trash2 } from 'lucide-react';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { DeleteButton } from '@/components/DeleteButton';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { searchCustomers, type CustomerRow } from '@/features/customers/api';
import { getInvoiceLines, listOpenInvoices } from '@/features/invoices/api';
import { searchItems, type ItemRow } from '@/features/items/api';
import { stockLocationsApi } from '@/features/setup/api';
import { useDebounced } from '@/hooks/use-debounced';
import { toast, toastError } from '@/hooks/use-toast';
import { deleteDocument } from '@/features/search/deletes';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, qty, round, toISODate, toNumber } from '@/lib/format';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { cn } from '@/lib/utils';
import { RETURN_KINDS, getReturn, getReturnLines, listAllReturns, listReturns, saveSalesReturn, type ReturnKind } from '../api';

const kindLabel = (k: string | null) => RETURN_KINDS.find((r) => r.value === k)?.label ?? k ?? '';

export function ReturnsPage() {
  const navigate = useNavigate();
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const [kind, setKind] = useState<ReturnKind | ''>('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const debounced = useDebounced(search);
  const filters = { search: debounced, kind, from, to };
  const returns = useQuery({ queryKey: ['returns', 'list', { ...filters, page, pageSize }], queryFn: () => listReturns({ ...filters, page, pageSize }), placeholderData: keepPreviousData });

  const onExport = async () => {
    try {
      const rows = await listAllReturns(filters);
      exportToExcel('returns', rows.map((r) => ({ 'Return no.': r.return_no, Date: dateDMY(r.return_date), Kind: kindLabel(r.kind), Customer: r.customer_name, Town: r.customer_town, Invoice: r.invoice_no, Location: r.location_name, Credit: Number(r.total ?? 0) })), 'Returns');
    } catch (err) {
      toastError(err, 'Export failed');
    }
  };

  return (
    <div className="space-y-3">
      <PageHeader
        title="Returns"
        description="Three kinds, never one: fresh (full credit, stock back), damage (breakage % credit, written off), rate difference (credit only, no stock)."
        actions={
          <>
            <Button variant="outline" size="sm" onClick={onExport} disabled={!returns.data?.total}><Download /> Excel</Button>
            {perms.canEdit('returns') && <Button asChild size="sm"><Link to="/returns/new"><Plus /> New return</Link></Button>}
          </>
        }
      />
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Return no., customer, invoice…" aria-label="Search returns" className="h-8 w-60" value={search} onChange={(ev) => { setSearch(ev.target.value); setPage(1); }} />
        <NativeSelect aria-label="Kind" className="h-8 w-48" value={kind} onChange={(ev) => { setKind(ev.target.value as ReturnKind | ''); setPage(1); }}>
          <option value="">All kinds</option>
          {RETURN_KINDS.map((k) => <option key={k.value} value={k.value}>{k.label}</option>)}
        </NativeSelect>
        <Input type="date" aria-label="From date" className="h-8 w-40" value={from} onChange={(ev) => { setFrom(ev.target.value); setPage(1); }} />
        <Input type="date" aria-label="To date" className="h-8 w-40" value={to} onChange={(ev) => { setTo(ev.target.value); setPage(1); }} />
      </div>
      {returns.isLoading ? <Spinner /> : returns.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load returns: {returns.error.message}</p>
      ) : returns.data && returns.data.rows.length === 0 ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No returns match.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>No.</TableHead><TableHead>Date</TableHead><TableHead>Kind</TableHead><TableHead>Customer</TableHead><TableHead>Invoice</TableHead><TableHead>Location</TableHead><TableHead className="text-right">Credit</TableHead>{perms.canDelete('returns') && <TableHead className="w-10" />}
              </TableRow>
            </TableHeader>
            <TableBody>
              {returns.data?.rows.map((r) => (
                <TableRow key={r.id} className="cursor-pointer" tabIndex={0} onClick={() => navigate(`/returns/${r.id}`)} onKeyDown={(ev) => ev.key === 'Enter' && navigate(`/returns/${r.id}`)}>
                  <TableCell className="font-medium">{r.return_no}</TableCell>
                  <TableCell>{dateDMY(r.return_date)}</TableCell>
                  <TableCell><Badge variant={r.kind === 'damage_return' ? 'destructive' : r.kind === 'rate_difference' ? 'outline' : 'secondary'}>{kindLabel(r.kind)}</Badge></TableCell>
                  <TableCell>{r.customer_name}</TableCell>
                  <TableCell className="text-muted-foreground">{r.invoice_no ?? '—'}</TableCell>
                  <TableCell className="text-muted-foreground">{r.location_name ?? '—'}</TableCell>
                  {perms.canDelete('returns') && (
                    <TableCell onClick={(ev) => ev.stopPropagation()}>
                      <DeleteButton
                        label={`return ${r.return_no}`}
                        detail="The goods that came back go out of stock again and the credit is reversed. If they have since been sold on, the screen will refuse and name the product."
                        invalidate={['returns']}
                        onDelete={() => deleteDocument('return', r.id ?? '')}
                      />
                    </TableCell>
                  )}
                  <TableCell className="num">{amount(r.total)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {returns.data && <Pager page={page} pageSize={pageSize} total={returns.data.total} onPage={setPage} onPageSize={(n) => { setPageSize(n); setPage(1); }} />}
    </div>
  );
}

interface DraftLine { key: string; item_id: string; item_code: string; item_name: string; units_per_box: number; boxes: number; rate: number; new_rate: number }
let seq = 0;

export function ReturnNewPage() {
  const perms = usePermissions();
  const me = useMe();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const pct = toNumber(me.data?.breakage_recovery_pct);
  const [kind, setKind] = useState<ReturnKind>('fresh_return');
  const [customer, setCustomer] = useState<CustomerRow | null>(null);
  const [invoiceId, setInvoiceId] = useState('');
  const [locationId, setLocationId] = useState('');
  const [date, setDate] = useState(toISODate());
  const [notes, setNotes] = useState('');
  const [lines, setLines] = useState<DraftLine[]>([]);
  const [entryItem, setEntryItem] = useState<ItemRow | null>(null);
  const [entryBoxes, setEntryBoxes] = useState('');
  const [entryRate, setEntryRate] = useState('');
  const [entryNew, setEntryNew] = useState('');
  const boxesRef = useRef<HTMLInputElement>(null);
  const codeWrap = useRef<HTMLDivElement>(null);

  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const openInvoices = useQuery({ queryKey: ['invoices', 'open', customer?.id], queryFn: () => listOpenInvoices(customer?.id ?? ''), enabled: Boolean(customer?.id) });
  const invoiceLines = useQuery({ queryKey: ['invoices', 'lines', invoiceId], queryFn: () => getInvoiceLines(invoiceId), enabled: Boolean(invoiceId) });

  useEffect(() => {
    if (locations.data && !locationId) {
      const g = locations.data.find((l) => l.is_active && l.kind === 'godown');
      if (g) setLocationId(g.id);
    }
  }, [locations.data, locationId]);

  const credit = (l: DraftLine) => {
    const q = l.boxes * l.units_per_box;
    if (kind === 'fresh_return') return round(q * l.rate, 2);
    if (kind === 'damage_return') return round((q * l.rate * pct) / 100, 2);
    return round(q * (l.rate - l.new_rate), 2);
  };
  const total = useMemo(() => round(lines.reduce((s, l) => s + credit(l), 0), 2), [lines, kind, pct]); // eslint-disable-line react-hooks/exhaustive-deps

  const addLine = (item: { id: string; code: string; name: string; upb: number }, boxes: number, rate: number, newRate: number) => {
    if (boxes <= 0) return;
    setLines((p) => [...p, { key: `r${++seq}`, item_id: item.id, item_code: item.code, item_name: item.name, units_per_box: item.upb, boxes, rate, new_rate: newRate }]);
  };
  const addEntry = () => {
    if (!entryItem?.id) return;
    addLine({ id: entryItem.id, code: entryItem.item_code ?? '', name: entryItem.name ?? '', upb: entryItem.units_per_box ?? 0 }, toNumber(entryBoxes), toNumber(entryRate), toNumber(entryNew));
    setEntryItem(null); setEntryBoxes(''); setEntryRate(''); setEntryNew('');
    setTimeout(() => codeWrap.current?.querySelector('input')?.focus(), 0);
  };

  const save = useMutation({
    mutationFn: async () => {
      if (!customer?.id) throw new Error('Choose a customer');
      if (lines.length === 0) throw new Error('Add at least one line');
      if (kind !== 'rate_difference' && !locationId) throw new Error('Choose the location the goods came back to');
      if (kind === 'rate_difference' && lines.some((l) => l.new_rate <= 0)) throw new Error('Every rate-difference line needs the new rate');
      return saveSalesReturn(
        { customer_id: customer.id, invoice_id: invoiceId || null, kind, return_date: date, location_id: kind === 'rate_difference' ? null : locationId, notes: notes || null },
        lines.map((l) => ({ item_id: l.item_id, boxes: l.boxes, rate: l.rate, new_rate: kind === 'rate_difference' ? l.new_rate : null })),
      );
    },
    onSuccess: async (id) => {
      await queryClient.invalidateQueries({ queryKey: ['returns'] });
      await queryClient.invalidateQueries({ queryKey: ['invoices'] });
      await queryClient.invalidateQueries({ queryKey: ['customers'] });
      toast({ title: 'Return saved' });
      navigate(`/returns/${id}`, { replace: true });
    },
    onError: (err) => toastError(err, 'Could not save the return'),
  });

  if (!perms.canEdit('returns')) return <p className="text-sm text-muted-foreground">Your role cannot record returns.</p>;
  const info = RETURN_KINDS.find((k) => k.value === kind);

  return (
    <div className="space-y-4">
      <PageHeader title="New return" actions={<Button asChild variant="ghost" size="sm"><Link to="/returns">← Returns</Link></Button>} />
      <Card>
        <CardContent className="space-y-3 pt-4">
          <div className="grid gap-2 md:grid-cols-3" role="radiogroup" aria-label="Kind of return">
            {RETURN_KINDS.map((k) => (
              <label key={k.value} className={cn('flex cursor-pointer items-start gap-2 rounded-md border p-2 text-sm', kind === k.value && 'border-primary bg-primary/5')}>
                <input type="radio" name="kind" className="mt-1 accent-primary" checked={kind === k.value} onChange={() => setKind(k.value)} />
                <span>
                  <span className="font-medium">{k.label}</span>
                  <span className="block text-xs text-muted-foreground">Money: {k.value === 'damage_return' ? `${pct}% of value` : k.money}. Stock: {k.stock}.</span>
                </span>
              </label>
            ))}
          </div>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <Field label="Customer" htmlFor="rt-customer" className="col-span-2">
              <Combobox<CustomerRow> id="rt-customer" value={customer} onChange={(c) => { setCustomer(c); setInvoiceId(''); }} search={searchCustomers} queryKey="customers" getKey={(c) => c.id ?? ''} getLabel={(c) => `${c.name ?? ''}${c.town ? ` — ${c.town}` : ''}`} placeholder="Type name, mobile or town…" autoFocus eager />
            </Field>
            <Field label="Against invoice (optional)" htmlFor="rt-invoice">
              <NativeSelect id="rt-invoice" value={invoiceId} onChange={(ev) => setInvoiceId(ev.target.value)} disabled={!customer}>
                <option value="">— none —</option>
                {(openInvoices.data ?? []).map((i) => <option key={i.invoice_id ?? ''} value={i.invoice_id ?? ''}>{i.invoice_no} · {dateDMY(i.invoice_date)} · bal {amount(i.balance)}</option>)}
              </NativeSelect>
            </Field>
            <Field label="Date" htmlFor="rt-date"><Input id="rt-date" type="date" value={date} onChange={(ev) => setDate(ev.target.value)} /></Field>
            {kind !== 'rate_difference' && (
              <Field label="Goods came back to" htmlFor="rt-location">
                <NativeSelect id="rt-location" value={locationId} onChange={(ev) => setLocationId(ev.target.value)}>
                  <option value="">— choose —</option>
                  {(locations.data ?? []).filter((l) => l.is_active).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
                </NativeSelect>
              </Field>
            )}
            <Field label="Notes" htmlFor="rt-notes" className="col-span-2"><Input id="rt-notes" value={notes} onChange={(ev) => setNotes(ev.target.value)} /></Field>
          </div>
        </CardContent>
      </Card>

      {invoiceId && invoiceLines.data && invoiceLines.data.length > 0 && (
        <div className="flex flex-wrap items-center gap-1 text-xs">
          <span className="text-muted-foreground">From the invoice:</span>
          {invoiceLines.data.map((l) => (
            <Button key={l.id} type="button" size="sm" variant="outline" className="h-7" onClick={() => addLine({ id: l.item_id ?? '', code: l.item_code ?? '', name: l.item_name ?? '', upb: Number(l.units_per_box ?? 0) }, Number(l.boxes ?? 0), Number(l.rate ?? 0), 0)}>
              {l.item_code} × {qty(l.boxes)} @ {amount(l.rate)}
            </Button>
          ))}
        </div>
      )}

      <div className="rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-36">CODE</TableHead><TableHead>Item</TableHead><TableHead className="w-20 text-right">Jars</TableHead><TableHead className="w-24 text-right">Boxes</TableHead><TableHead className="w-24 text-right">Qty</TableHead><TableHead className="w-28 text-right">Billed rate</TableHead>
              {kind === 'rate_difference' && <TableHead className="w-28 text-right">New rate</TableHead>}
              <TableHead className="w-32 text-right">Credit</TableHead><TableHead className="w-10" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {lines.map((l) => (
              <TableRow key={l.key}>
                <TableCell className="font-medium">{l.item_code}</TableCell>
                <TableCell>{l.item_name}</TableCell>
                <TableCell className="num text-muted-foreground">{qty(l.units_per_box)}</TableCell>
                <TableCell className="num"><Input type="number" step="0.001" className="num h-8" aria-label={`Boxes ${l.item_code}`} value={l.boxes} onChange={(ev) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, boxes: toNumber(ev.target.value) } : x))} /></TableCell>
                <TableCell className="num text-muted-foreground">{qty(l.boxes * l.units_per_box)}</TableCell>
                <TableCell className="num"><Input type="number" step="0.01" className="num h-8" aria-label={`Rate ${l.item_code}`} value={l.rate} onChange={(ev) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, rate: toNumber(ev.target.value) } : x))} /></TableCell>
                {kind === 'rate_difference' && <TableCell className="num"><Input type="number" step="0.01" className="num h-8" aria-label={`New rate ${l.item_code}`} value={l.new_rate} onChange={(ev) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, new_rate: toNumber(ev.target.value) } : x))} /></TableCell>}
                <TableCell className="num font-medium">{amount(credit(l))}</TableCell>
                <TableCell><Button type="button" variant="ghost" size="icon" aria-label={`Remove ${l.item_code}`} onClick={() => setLines((p) => p.filter((x) => x.key !== l.key))}><Trash2 className="text-destructive" /></Button></TableCell>
              </TableRow>
            ))}
            <TableRow className="bg-muted/30">
              <TableCell>
                <div ref={codeWrap}>
                  <Combobox<ItemRow> value={entryItem} onChange={setEntryItem} search={(q) => searchItems(q, { finishedOnly: true })} queryKey="items" getKey={(it) => it.id ?? ''} getLabel={(it) => it.item_code ?? ''} renderOption={(it) => <span><span className="font-medium">{it.item_code}</span> {it.name}</span>} placeholder="Code or name…" aria-label="Item code or name"
                    onPicked={(it) => { setEntryRate(String(toNumber(it.unit_rate))); setTimeout(() => boxesRef.current?.focus(), 0); }} />
                </div>
              </TableCell>
              <TableCell className="text-muted-foreground">{entryItem?.name ?? ''}</TableCell>
              <TableCell className="num text-muted-foreground">{entryItem ? qty(entryItem.units_per_box) : ''}</TableCell>
              <TableCell><Input ref={boxesRef} type="number" step="0.001" className="num h-8" aria-label="Boxes" value={entryBoxes} onChange={(ev) => setEntryBoxes(ev.target.value)} disabled={!entryItem} onKeyDown={(ev) => ev.key === 'Enter' && (ev.preventDefault(), addEntry())} /></TableCell>
              <TableCell className="num text-muted-foreground">{entryItem && entryBoxes ? qty(toNumber(entryBoxes) * (entryItem.units_per_box ?? 0)) : ''}</TableCell>
              <TableCell><Input type="number" step="0.01" className="num h-8" aria-label="Billed rate" value={entryRate} onChange={(ev) => setEntryRate(ev.target.value)} disabled={!entryItem} onKeyDown={(ev) => ev.key === 'Enter' && (ev.preventDefault(), addEntry())} /></TableCell>
              {kind === 'rate_difference' && <TableCell><Input type="number" step="0.01" className="num h-8" aria-label="New rate" value={entryNew} onChange={(ev) => setEntryNew(ev.target.value)} disabled={!entryItem} onKeyDown={(ev) => ev.key === 'Enter' && (ev.preventDefault(), addEntry())} /></TableCell>}
              <TableCell />
              <TableCell><Button type="button" size="sm" variant="secondary" onClick={addEntry} disabled={!entryItem}>Add</Button></TableCell>
            </TableRow>
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell colSpan={kind === 'rate_difference' ? 7 : 6} className="text-right font-semibold">Credit to customer ({info?.label})</TableCell>
              <TableCell className="num font-semibold">{amount(total)}</TableCell>
              <TableCell />
            </TableRow>
          </TableFooter>
        </Table>
      </div>

      <div className="flex justify-end gap-2">
        <Button type="button" variant="outline" onClick={() => navigate('/returns')}>Cancel</Button>
        <Button type="button" onClick={() => save.mutate()} disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save return'}</Button>
      </div>
    </div>
  );
}

export function ReturnViewPage() {
  const { id } = useParams();
  const ret = useQuery({ queryKey: ['returns', 'one', id], queryFn: () => getReturn(id ?? ''), enabled: Boolean(id) });
  const lines = useQuery({ queryKey: ['returns', 'lines', id], queryFn: () => getReturnLines(id ?? ''), enabled: Boolean(id) });
  if (ret.isLoading || lines.isLoading) return <Spinner label="Loading return…" />;
  if (!ret.data || !lines.data) return <p role="alert" className="text-sm text-destructive">Return not found.</p>;
  const r = ret.data;
  return (
    <div className="space-y-4">
      <PageHeader title={`Return ${r.return_no}`} description={`${kindLabel(r.kind)} · ${dateDMY(r.return_date)} · ${r.customer_name}${r.invoice_no ? ` · against ${r.invoice_no}` : ''}${r.location_name ? ` · to ${r.location_name}` : ''}`} actions={<Button asChild variant="ghost" size="sm"><Link to="/returns">← Returns</Link></Button>} />
      <div className="rounded-md border">
        <Table>
          <TableHeader><TableRow><TableHead>CODE</TableHead><TableHead>Item</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead className="text-right">Qty</TableHead><TableHead className="text-right">Billed rate</TableHead>{r.kind === 'rate_difference' && <TableHead className="text-right">New rate</TableHead>}<TableHead className="text-right">Credit</TableHead></TableRow></TableHeader>
          <TableBody>
            {lines.data.map((l) => (
              <TableRow key={l.id}>
                <TableCell className="font-medium">{l.item_code}</TableCell><TableCell>{l.item_name}</TableCell>
                <TableCell className="num">{qty(l.boxes)}</TableCell><TableCell className="num">{qty(l.qty)}</TableCell><TableCell className="num">{amount(l.old_rate)}</TableCell>
                {r.kind === 'rate_difference' && <TableCell className="num">{amount(l.new_rate)}</TableCell>}
                <TableCell className="num">{amount(l.amount)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter><TableRow><TableCell colSpan={r.kind === 'rate_difference' ? 6 : 5} className="text-right font-semibold">Credit</TableCell><TableCell className="num font-semibold">{amount(r.total)}</TableCell></TableRow></TableFooter>
        </Table>
      </div>
    </div>
  );
}
