import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowLeft, Check, Plus, Trash2, X } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Textarea } from '@/components/ui/textarea';
import { usePermissions } from '@/features/auth/hooks';
import { getCustomer, searchCustomers, type CustomerRow } from '@/features/customers/api';
import { effectiveUnitRate, searchItems, type ItemRow } from '@/features/items/api';
import { stockLocationsApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { amount, dateTimeDMY, money, qty, round, toISODate, toNumber } from '@/lib/format';
import { invoiceLine } from '@/lib/units';
import { cn } from '@/lib/utils';
import { convertInboundToOrder } from '@/features/documents/api';
import { convertInboundOrder, getInboundOrder, inboundOrderLines, orderTone, rejectInboundOrder, type InboundLine } from '../api';

interface EditLine {
  key: number;
  raw: InboundLine | null;
  item: ItemRow | null;
  boxes: number;
  rate: number;
}

/**
 * T6.5 — raw text beside parsed lines, low confidence highlighted, edit, then
 * "Convert to invoice". The button is the only way an order becomes a bill.
 */
export function InboundOrderPage() {
  const { id = '' } = useParams();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const perms = usePermissions();
  const canEdit = perms.canEdit('messaging') && perms.canEdit('invoices');
  const order = useQuery({ queryKey: ['messaging', 'order', id], queryFn: () => getInboundOrder(id), enabled: Boolean(id) });
  const parsed = useQuery({ queryKey: ['messaging', 'order-lines', id], queryFn: () => inboundOrderLines(id), enabled: Boolean(id) });
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const presetCustomer = useQuery({ queryKey: ['customers', 'one', order.data?.customer_id], queryFn: () => getCustomer(order.data?.customer_id ?? ''), enabled: Boolean(order.data?.customer_id) });

  const [customer, setCustomer] = useState<CustomerRow | null>(null);
  const [date, setDate] = useState(toISODate());
  const [locationId, setLocationId] = useState('');
  const [notes, setNotes] = useState('');
  const [lines, setLines] = useState<EditLine[]>([]);
  const [rejecting, setRejecting] = useState<string | null>(null);

  useEffect(() => { if (presetCustomer.data && !customer) setCustomer(presetCustomer.data); }, [presetCustomer.data, customer]);
  useEffect(() => { if (locations.data?.length && !locationId) setLocationId(locations.data.find((l) => l.kind === 'godown')?.id ?? locations.data[0]?.id ?? ''); }, [locations.data, locationId]);
  useEffect(() => {
    if (!parsed.data || lines.length) return;
    setLines(parsed.data.map((l, i) => ({
      key: i,
      raw: l,
      item: l.item_id ? ({ id: l.item_id, item_code: l.item_code, name: l.item_name, units_per_box: l.units_per_box, unit_rate: l.rate } as ItemRow) : null,
      boxes: toNumber(l.boxes),
      rate: toNumber(l.rate),
    })));
  }, [parsed.data, lines.length]);

  const ready = lines.filter((l) => l.item && l.boxes > 0);
  const total = useMemo(() => ready.reduce((s, l) => s + ((l.item?.units_per_box ?? 0) > 0 ? invoiceLine({ boxes: l.boxes, unitsPerBox: l.item?.units_per_box ?? 0, rate: l.rate }).total : 0), 0), [ready]);
  const update = (key: number, patch: Partial<EditLine>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  const pickItem = async (key: number, item: ItemRow | null) => {
    update(key, { item, rate: toNumber(item?.unit_rate) });
    if (item?.id && customer?.id) {
      try {
        const r = await effectiveUnitRate(item.id, customer.id, date);
        update(key, { rate: r });
      } catch {
        // keep the list rate
      }
    }
  };

  const convert = useMutation({
    mutationFn: () => {
      if (!customer?.id) throw new Error('Pick the customer first');
      if (!locationId) throw new Error('Pick the stock location');
      if (!ready.length) throw new Error('Every line needs an item and boxes; remove the ones you cannot match');
      const unresolved = lines.filter((l) => !l.item || l.boxes <= 0);
      if (unresolved.length) throw new Error(`${unresolved.length} line${unresolved.length === 1 ? '' : 's'} still unmatched — fix or remove them`);
      return convertInboundOrder(id, { customer_id: customer.id, invoice_date: date, location_id: locationId, notes: notes || null, freight: 0, discount: 0, round_off: 0 }, ready.map((l) => ({ item_id: l.item?.id ?? '', boxes: l.boxes, rate: l.rate })));
    },
    onSuccess: async (invId) => {
      toast({ title: 'Draft invoice created', description: 'Check it and confirm from the invoice screen.' });
      await qc.invalidateQueries({ queryKey: ['messaging'] });
      await qc.invalidateQueries({ queryKey: ['dashboard'] });
      navigate(`/invoices/${invId}`);
    },
    onError: (e) => toastError(e, 'Could not convert'),
  });
  const toOrder = useMutation({
    mutationFn: () => {
      if (!customer?.id) throw new Error('Pick the customer first');
      if (!ready.length) throw new Error('Every line needs an item and boxes');
      const unresolved = lines.filter((l) => !l.item || l.boxes <= 0);
      if (unresolved.length) throw new Error(`${unresolved.length} line${unresolved.length === 1 ? '' : 's'} still unmatched — fix or remove them`);
      return convertInboundToOrder(id, { customer_id: customer.id, notes: notes || null }, ready.map((l) => ({ item_id: l.item?.id ?? '', boxes: l.boxes, rate: l.rate })));
    },
    onSuccess: async (orderId) => {
      toast({ title: 'Sale order created', description: 'Deliver it in parts from the order screen; each part becomes an invoice.' });
      await qc.invalidateQueries({ queryKey: ['messaging'] });
      await qc.invalidateQueries({ queryKey: ['orders'] });
      navigate(`/orders/${orderId}`);
    },
    onError: (e) => toastError(e, 'Could not create the order'),
  });
  const reject = useMutation({
    mutationFn: (reason: string) => rejectInboundOrder(id, reason),
    onSuccess: async () => { toast({ title: 'Order rejected' }); await qc.invalidateQueries({ queryKey: ['messaging'] }); navigate('/messaging'); },
    onError: (e) => toastError(e, 'Could not reject'),
  });

  if (order.isLoading) return <Spinner />;
  if (order.error || !order.data) return <p role="alert" className="text-sm text-destructive">Could not load the order: {order.error?.message}</p>;
  const o = order.data;
  const open = o.status === 'new' || o.status === 'confirmed';
  const lowCount = lines.filter((l) => l.raw?.low_confidence).length;

  return (
    <div className="space-y-3">
      <PageHeader
        title={`Order from ${o.customer_name ?? o.from_number ?? 'unknown'}`}
        description={<span className="flex flex-wrap items-center gap-2">{dateTimeDMY(o.created_at)} · via {o.source} <Badge variant={orderTone[o.status ?? 'new']}>{o.status}</Badge>{o.invoice_no && <Link to={`/invoices/${o.invoice_id}`} className="text-primary hover:underline">{o.invoice_no}</Link>}{o.order_no && <Link to={`/orders/${o.order_id}`} className="text-primary hover:underline">order {o.order_no}</Link>}{o.handled_by_name && <span className="text-xs">handled by {o.handled_by_name} {dateTimeDMY(o.handled_at)}</span>}</span>}
        actions={<Button asChild variant="outline" size="sm"><Link to="/messaging"><ArrowLeft /> Queue</Link></Button>}
      />

      <div className="grid gap-3 lg:grid-cols-5">
        <Card className="lg:col-span-2">
          <CardHeader><CardTitle>What the customer said</CardTitle></CardHeader>
          <CardContent className="space-y-3 text-sm">
            {o.raw_text && <p className="whitespace-pre-wrap rounded-md bg-muted/50 p-3">{o.raw_text}</p>}
            {o.transcript && <div><div className="text-xs uppercase text-muted-foreground">Transcript</div><p className="whitespace-pre-wrap rounded-md bg-muted/50 p-3">{o.transcript}</p></div>}
            {o.audio_url && <audio controls src={o.audio_url} className="w-full" />}
            {!o.raw_text && !o.transcript && !o.audio_url && <p className="text-muted-foreground">No text came with this order.</p>}
            <div className="text-xs text-muted-foreground">From {o.from_number ?? o.mobile1}{o.confidence !== null && o.confidence !== undefined ? ` · parser confidence ${qty(toNumber(o.confidence) * 100, 0)}%` : ''}{o.campaign_kind === 'order_call' ? ` · taken on an order call${o.call_duration ? ` (${o.call_duration}s)` : ''}${o.campaign_note ? ` · ${o.campaign_note}` : ''}` : ''}</div>
            {o.reject_reason && <p className="text-destructive">Rejected: {o.reject_reason}</p>}
            <Field label="Customer" htmlFor="io-cust">
              <Combobox<CustomerRow> id="io-cust" value={customer} onChange={setCustomer} search={searchCustomers} queryKey="customers-pick" getKey={(c) => c.id ?? ''} getLabel={(c) => `${c.name}${c.town ? ` — ${c.town}` : ''}`} renderOption={(c) => <span><span className="font-medium">{c.name}</span> <span className="text-muted-foreground">{c.town} · {c.mobile1}</span></span>} placeholder={o.customer_id ? '' : 'Unknown number — pick the customer'} disabled={!open || !canEdit} eager />
            </Field>
            {!o.customer_id && open && <p className="text-xs text-amber-700">This number is not on any customer. Pick the right one, or add the number to their record first.</p>}
            <div className="grid grid-cols-2 gap-2">
              <Field label="Invoice date" htmlFor="io-date"><Input id="io-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} disabled={!open} /></Field>
              <Field label="From location" htmlFor="io-loc">
                <NativeSelect id="io-loc" value={locationId} onChange={(e) => setLocationId(e.target.value)} disabled={!open}>
                  {(locations.data ?? []).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
                </NativeSelect>
              </Field>
            </div>
            <Field label="Notes on the bill" htmlFor="io-notes"><Textarea id="io-notes" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} disabled={!open} /></Field>
          </CardContent>
        </Card>

        <Card className="lg:col-span-3">
          <CardHeader className="flex-row items-center justify-between space-y-0">
            <CardTitle>Lines {lowCount > 0 && <Badge variant="outline" className="ml-2 border-amber-400 text-amber-800">{lowCount} to check</Badge>}</CardTitle>
            {open && canEdit && <Button size="sm" variant="outline" onClick={() => setLines((ls) => [...ls, { key: Date.now(), raw: null, item: null, boxes: 1, rate: 0 }])}><Plus /> Line</Button>}
          </CardHeader>
          <CardContent>
            {parsed.isLoading ? <Spinner /> : (
              <Table>
                <TableHeader><TableRow><TableHead className="w-44">Parsed</TableHead><TableHead>Item</TableHead><TableHead className="w-20 text-right">Boxes</TableHead><TableHead className="w-24 text-right">Rate</TableHead><TableHead className="w-28 text-right">Amount</TableHead><TableHead className="w-8" /></TableRow></TableHeader>
                <TableBody>
                  {lines.map((l) => {
                    const upb = l.item?.units_per_box ?? 0;
                    const amt = l.item && upb > 0 ? invoiceLine({ boxes: l.boxes, unitsPerBox: upb, rate: l.rate }).total : 0;
                    const low = l.raw?.low_confidence;
                    return (
                      <TableRow key={l.key} className={cn(low && 'bg-amber-50/70', !l.item && 'bg-red-50/50')}>
                        <TableCell className="text-xs">
                          {l.raw ? (
                            <>
                              <div className="font-medium">{l.raw.raw_code ?? l.raw.raw_name ?? '?'}</div>
                              <div className="text-muted-foreground">{qty(l.raw.qty, 0)} {l.raw.uom ?? 'box'}{l.raw.confidence !== null && l.raw.confidence !== undefined ? ` · ${qty(toNumber(l.raw.confidence) * 100, 0)}%` : ''}</div>
                              <div className={cn('text-[10px] uppercase', l.raw.match === 'code' ? 'text-green-700' : l.raw.match === 'name' ? 'text-amber-700' : 'text-destructive')}>{l.raw.match === 'code' ? 'code match' : l.raw.match === 'name' ? 'name match — check' : 'not found'}</div>
                            </>
                          ) : <span className="text-muted-foreground">added</span>}
                        </TableCell>
                        <TableCell>
                          <Combobox<ItemRow> value={l.item} onChange={(i) => void pickItem(l.key, i)} search={(q) => searchItems(q, { finishedOnly: true })} queryKey="items-finished" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code} — ${i.name}`} renderOption={(i) => <span><span className="font-medium">{i.item_code}</span> {i.name}</span>} placeholder="Code or name…" disabled={!open || !canEdit} aria-label="Item" />
                          {l.item && <div className="text-xs text-muted-foreground">{upb} per box</div>}
                        </TableCell>
                        <TableCell><Input type="number" min={0} step="0.5" className="num h-8" value={l.boxes} onChange={(e) => update(l.key, { boxes: toNumber(e.target.value) })} disabled={!open || !canEdit} aria-label="Boxes" /></TableCell>
                        <TableCell><Input type="number" min={0} step="0.01" className="num h-8" value={l.rate} onChange={(e) => update(l.key, { rate: toNumber(e.target.value) })} disabled={!open || !canEdit} aria-label="Rate" /></TableCell>
                        <TableCell className="num">{amount(amt)}</TableCell>
                        <TableCell>{open && canEdit && <Button size="sm" variant="ghost" aria-label="Remove line" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))}><Trash2 /></Button>}</TableCell>
                      </TableRow>
                    );
                  })}
                  {!lines.length && <TableRow><TableCell colSpan={6} className="text-center text-sm text-muted-foreground">No lines parsed — add them from the text on the left.</TableCell></TableRow>}
                </TableBody>
                <TableFooter>
                  <TableRow><TableCell colSpan={2} className="text-right">Total</TableCell><TableCell className="num">{qty(ready.reduce((s, l) => s + l.boxes, 0))}</TableCell><TableCell /><TableCell className="num">{money(round(total, 2))}</TableCell><TableCell /></TableRow>
                </TableFooter>
              </Table>
            )}
            {open && canEdit && (
              <div className="mt-3 flex flex-wrap items-center gap-2">
                {rejecting === null ? (
                  <Button variant="outline" onClick={() => setRejecting('')}><X /> Reject</Button>
                ) : (
                  <>
                    <Input className="h-9 w-64" placeholder="Why? (optional)" value={rejecting} onChange={(e) => setRejecting(e.target.value)} autoFocus />
                    <Button variant="destructive" onClick={() => reject.mutate(rejecting)} disabled={reject.isPending}>Confirm reject</Button>
                    <Button variant="ghost" onClick={() => setRejecting(null)}>Keep</Button>
                  </>
                )}
                <Button className="ml-auto" variant="secondary" onClick={() => toOrder.mutate()} disabled={toOrder.isPending || !customer || !ready.length} title="Keep it as a promise to deliver in parts">Convert to sale order</Button>
                <Button onClick={() => convert.mutate()} disabled={convert.isPending || !customer || !ready.length}><Check /> Convert to invoice</Button>
              </div>
            )}
            {!canEdit && open && <p className="mt-3 text-xs text-muted-foreground">Converting needs Messaging and Invoice edit rights.</p>}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
