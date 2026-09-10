import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, PackageCheck, Plus } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Link, NavLink, useNavigate, useParams } from 'react-router-dom';
import { DeleteButton } from '@/components/DeleteButton';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { getCustomer, searchCustomers, type CustomerRow } from '@/features/customers/api';
import { searchSuppliers, type SupplierRow } from '@/features/purchases/api';
import { stockLocationsApi } from '@/features/setup/api';
import { useDebounced } from '@/hooks/use-debounced';
import { toast, toastError } from '@/hooks/use-toast';
import { deleteDocument } from '@/features/search/deletes';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { cancelOrder, fulfilOrder, getOrder, getOrderFulfilments, getOrderLines, listOrders, nextLineKey, saveOrder, stateTone, type DocLine, type DocState, type OrderKind, type OrderLineRow, type OrderRow } from '../api';
import { DocLines } from '../components/DocLines';

const KIND_LABEL: Record<OrderKind, string> = { sale: 'Sale orders', purchase: 'Purchase orders' };

// ------------------------------------------------------------------ list
export function OrdersPage({ kind = 'sale' }: { kind?: OrderKind }) {
  const navigate = useNavigate();
  const perms = usePermissions();
  const module = kind === 'sale' ? 'invoices' : 'purchases';
  const [search, setSearch] = useState('');
  const [state, setState] = useState<DocState | ''>('');
  const debounced = useDebounced(search);
  const rows = useQuery({ queryKey: ['orders', kind, state, debounced], queryFn: () => listOrders({ kind, state, search: debounced }) });
  const list = rows.data ?? [];
  return (
    <div className="space-y-3">
      <PageHeader title="Orders" description="What has been promised but not yet billed or received. Deliver or receive in parts; each part becomes an invoice or a purchase bill."
        actions={<><Button variant="outline" size="sm" onClick={() => exportToExcel(`${kind}-orders`, list.map((r) => ({ 'Order no.': r.order_no, Date: dateDMY(r.order_date), Due: r.due_date ? dateDMY(r.due_date) : '', Party: r.party_name, State: r.state, Boxes: toNumber(r.total_boxes), Delivered: toNumber(r.delivered_boxes), Total: toNumber(r.total), Advance: toNumber(r.advance) })), 'Orders')} disabled={!list.length}><Download /> Excel</Button>{perms.canEdit(module) && <Button asChild size="sm"><Link to={`/orders/new?kind=${kind}`}><Plus /> New {kind} order</Link></Button>}</>} />
      <nav className="flex gap-1 border-b" aria-label="Order kind">
        {(['sale', 'purchase'] as OrderKind[]).map((k) => <NavLink key={k} to={k === 'sale' ? '/orders' : '/orders/purchase'} end className={({ isActive }) => cn('-mb-px border-b-2 px-3 py-1.5 text-sm', isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}>{KIND_LABEL[k]}</NavLink>)}
      </nav>
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Order no., party…" aria-label="Search" className="h-8 w-60" value={search} onChange={(e) => setSearch(e.target.value)} />
        <NativeSelect aria-label="State" className="h-8 w-36" value={state} onChange={(e) => setState(e.target.value as DocState | '')}><option value="">All states</option><option value="open">Open</option><option value="partial">Partial</option><option value="completed">Completed</option><option value="cancelled">Cancelled</option></NativeSelect>
      </div>
      {rows.isLoading ? <Spinner /> : rows.error ? <p role="alert" className="text-sm text-destructive">{rows.error.message}</p> : !list.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No {kind} orders.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>No.</TableHead><TableHead>Date</TableHead><TableHead>Due</TableHead><TableHead>{kind === 'sale' ? 'Customer' : 'Supplier'}</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead className="text-right">Delivered</TableHead><TableHead className="text-right">Total</TableHead><TableHead>State</TableHead>{perms.canDelete('invoices') && <TableHead className="w-10" />}</TableRow></TableHeader>
            <TableBody>
              {list.map((r) => (
                <TableRow key={r.id ?? ''} className={cn('cursor-pointer', r.is_overdue && 'bg-amber-50/60')} tabIndex={0} onClick={() => navigate(`/orders/${r.id}`)} onKeyDown={(ev) => ev.key === 'Enter' && navigate(`/orders/${r.id}`)}>
                  <TableCell className="font-medium">{r.order_no}</TableCell><TableCell>{dateDMY(r.order_date)}</TableCell>
                  <TableCell className={r.is_overdue ? 'text-amber-700' : ''}>{r.due_date ? dateDMY(r.due_date) : '—'}</TableCell>
                  <TableCell>{r.party_name}<div className="text-xs text-muted-foreground">{r.party_town}</div></TableCell>
                  <TableCell className="num">{qty(r.total_boxes)}</TableCell><TableCell className="num">{qty(r.delivered_boxes)}</TableCell><TableCell className="num">{amount(r.total)}</TableCell>
                  <TableCell><Badge variant={stateTone[r.state ?? 'open']}>{r.state}</Badge>{r.source_inbound_id && <div className="text-xs text-muted-foreground">from WhatsApp / call</div>}</TableCell>
                  {perms.canDelete('invoices') && (
                    <TableCell onClick={(ev) => ev.stopPropagation()}>
                      <DeleteButton
                        label={`order ${r.order_no}`}
                        detail="The order is marked cancelled. It has posted no stock and no ledger entry, so nothing else changes."
                        invalidate={['orders']}
                        onDelete={() => deleteDocument('order', r.id ?? '')}
                      />
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ edit / view
export function OrderEditPage() {
  const { id } = useParams();
  const isNew = !id || id === 'new';
  const kindParam = (new URLSearchParams(window.location.search).get('kind') === 'purchase' ? 'purchase' : 'sale') as OrderKind;
  const order = useQuery({ queryKey: ['orders', 'one', id], queryFn: () => getOrder(id ?? ''), enabled: !isNew });
  const lines = useQuery({ queryKey: ['orders', 'lines', id], queryFn: () => getOrderLines(id ?? ''), enabled: !isNew });
  if (!isNew && (order.isLoading || lines.isLoading)) return <Spinner />;
  if (!isNew && (!order.data || !lines.data)) return <p role="alert" className="text-sm text-destructive">Order not found.</p>;
  const kind = order.data?.kind ?? kindParam;
  return (
    <div className="space-y-4">
      <PageHeader title={isNew ? `New ${kind} order` : `${kind === 'sale' ? 'Sale' : 'Purchase'} order ${order.data?.order_no}`} actions={<Button asChild variant="ghost" size="sm"><Link to={kind === 'sale' ? '/orders' : '/orders/purchase'}>← Orders</Link></Button>} />
      <OrderEditor key={`${order.data?.id ?? 'new'}-${order.data?.state ?? ''}-${order.data?.delivered_boxes ?? ''}`} kind={kind} order={order.data ?? undefined} lineRows={lines.data ?? []} />
    </div>
  );
}

function OrderEditor({ kind, order, lineRows }: { kind: OrderKind; order?: OrderRow; lineRows: OrderLineRow[] }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const perms = usePermissions();
  const module = kind === 'sale' ? 'invoices' : 'purchases';
  const editable = perms.canEdit(module) && (!order || (order.state === 'open' && toNumber(order.delivered_boxes) === 0));
  const [customer, setCustomer] = useState<CustomerRow | null>(null);
  const [supplier, setSupplier] = useState<SupplierRow | null>(null);
  useEffect(() => { if (order?.customer_id && !customer) getCustomer(order.customer_id).then(setCustomer).catch(() => undefined); }, [order?.customer_id, customer]);
  useEffect(() => { if (order?.supplier_id && !supplier) searchSuppliers('').then((s) => setSupplier(s.find((x) => x.id === order.supplier_id) ?? null)).catch(() => undefined); }, [order?.supplier_id, supplier]);
  const [date, setDate] = useState(order?.order_date ?? toISODate());
  const [due, setDue] = useState(order?.due_date ?? '');
  const [advance, setAdvance] = useState(String(toNumber(order?.advance)));
  const [notes, setNotes] = useState(order?.notes ?? '');
  const [lines, setLines] = useState<DocLine[]>(lineRows.map((l) => ({ key: nextLineKey(), item_id: l.item_id ?? '', item_code: l.item_code ?? '', item_name: l.item_name ?? '', units_per_box: toNumber(l.units_per_box), boxes: toNumber(l.boxes), rate: toNumber(l.rate) })));
  const [fulfilling, setFulfilling] = useState(false);
  const fulfilments = useQuery({ queryKey: ['orders', 'fulfilments', order?.id], queryFn: () => getOrderFulfilments(order?.id ?? ''), enabled: Boolean(order?.id) });
  const invalidate = () => qc.invalidateQueries({ queryKey: ['orders'] });

  const save = useMutation({
    mutationFn: async () => {
      if (kind === 'sale' && !customer?.id) throw new Error('Choose a customer');
      if (kind === 'purchase' && !supplier?.id) throw new Error('Choose a supplier');
      if (!lines.length) throw new Error('Add at least one line');
      return saveOrder({ id: order?.id ?? undefined, kind, customer_id: customer?.id ?? null, supplier_id: supplier?.id ?? null, order_date: date, due_date: due || null, advance: toNumber(advance), notes: notes || null }, lines.map((l) => ({ item_id: l.item_id, boxes: l.boxes, rate: l.rate })));
    },
    onSuccess: async (newId) => { await invalidate(); toast({ title: 'Order saved' }); navigate(`/orders/${newId}`, { replace: true }); },
    onError: (err) => toastError(err, 'Could not save'),
  });
  const cancel = useMutation({
    mutationFn: () => cancelOrder(order?.id ?? ''),
    onSuccess: async () => { await invalidate(); toast({ title: 'Order cancelled' }); },
    onError: (err) => toastError(err, 'Could not cancel'),
  });
  const canFulfil = order && perms.canEdit(module) && (order.state === 'open' || order.state === 'partial');

  return (
    <div className="space-y-4">
      {order && (
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={stateTone[order.state ?? 'open']}>{order.state}</Badge>
          <span className="text-sm text-muted-foreground">{dateDMY(order.order_date)}{order.due_date ? ` · due ${dateDMY(order.due_date)}` : ''} · {qty(order.delivered_boxes)} of {qty(order.total_boxes)} boxes {kind === 'sale' ? 'delivered' : 'received'}</span>
          <span className="ml-auto flex gap-2">
            {canFulfil && <Button size="sm" onClick={() => setFulfilling(true)}><PackageCheck /> {kind === 'sale' ? 'Deliver' : 'Receive'}</Button>}
            {canFulfil && <Button size="sm" variant="ghost" className="text-destructive" onClick={() => cancel.mutate()} disabled={cancel.isPending}>Cancel order</Button>}
          </span>
        </div>
      )}
      <Card>
        <CardContent className="grid grid-cols-2 gap-3 pt-4 md:grid-cols-4">
          {kind === 'sale' ? (
            <Field label="Customer" htmlFor="or-cust" className="col-span-2"><Combobox<CustomerRow> id="or-cust" value={customer} onChange={setCustomer} search={searchCustomers} queryKey="customers" getKey={(c) => c.id ?? ''} getLabel={(c) => `${c.name ?? ''}${c.town ? ` — ${c.town}` : ''}`} placeholder="Type name, mobile or town…" autoFocus={!order} disabled={!editable} eager /></Field>
          ) : (
            <Field label="Supplier" htmlFor="or-sup" className="col-span-2"><Combobox<SupplierRow> id="or-sup" value={supplier} onChange={setSupplier} search={searchSuppliers} queryKey="suppliers" getKey={(s) => s.id ?? ''} getLabel={(s) => s.name ?? ''} placeholder="Supplier…" autoFocus={!order} disabled={!editable} eager /></Field>
          )}
          <Field label="Order date" htmlFor="or-date"><Input id="or-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} disabled={!editable} /></Field>
          <Field label="Due date" htmlFor="or-due"><Input id="or-due" type="date" value={due} onChange={(e) => setDue(e.target.value)} disabled={!editable} /></Field>
          <Field label="Advance received (₹)" htmlFor="or-adv"><Input id="or-adv" type="number" step="0.01" className="num" value={advance} onChange={(e) => setAdvance(e.target.value)} disabled={!editable} /></Field>
          <Field label="Notes" htmlFor="or-notes" className="col-span-3"><Input id="or-notes" value={notes} onChange={(e) => setNotes(e.target.value)} disabled={!editable} /></Field>
        </CardContent>
      </Card>
      {order && !editable ? (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>CODE</TableHead><TableHead>Item</TableHead><TableHead className="text-right">Jars</TableHead><TableHead className="text-right">Ordered</TableHead><TableHead className="text-right">{kind === 'sale' ? 'Delivered' : 'Received'}</TableHead><TableHead className="text-right">Pending</TableHead><TableHead className="text-right">Rate</TableHead><TableHead className="text-right">Amount</TableHead></TableRow></TableHeader>
            <TableBody>{lineRows.map((l) => <TableRow key={l.id ?? ''}><TableCell className="font-medium">{l.item_code}</TableCell><TableCell>{l.item_name}</TableCell><TableCell className="num text-muted-foreground">{qty(l.units_per_box)}</TableCell><TableCell className="num">{qty(l.boxes)}</TableCell><TableCell className="num">{qty(l.delivered_boxes)}</TableCell><TableCell className={cn('num font-medium', toNumber(l.pending_boxes) > 0 && 'text-amber-700')}>{qty(l.pending_boxes)}</TableCell><TableCell className="num">{amount(l.rate)}</TableCell><TableCell className="num">{amount(l.amount)}</TableCell></TableRow>)}</TableBody>
          </Table>
        </div>
      ) : (
        <DocLines lines={lines} onChange={setLines} editable={editable} customerId={customer?.id} date={date} rateSource={kind} />
      )}
      {order && (fulfilments.data?.length ?? 0) > 0 && (
        <Card><CardHeader className="pb-2"><CardTitle className="text-base">{kind === 'sale' ? 'Deliveries' : 'Receipts of goods'}</CardTitle></CardHeader><CardContent>
          <ul className="space-y-1 text-sm">{fulfilments.data?.map((f) => <li key={f.id ?? ''}>{dateDMY(f.doc_date)} · <Link to={f.ref_table === 'invoices' ? `/invoices/${f.ref_id}` : `/purchases/${f.ref_id}`} className="font-medium text-primary hover:underline">{f.doc_no ?? f.ref_table}</Link> · {qty(f.boxes)} boxes</li>)}</ul>
        </CardContent></Card>
      )}
      {editable && <div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={() => navigate(kind === 'sale' ? '/orders' : '/orders/purchase')}>Back</Button><Button type="button" disabled={save.isPending} onClick={() => save.mutate()}>{save.isPending ? 'Saving…' : 'Save order'}</Button></div>}
      {order && fulfilling && <FulfilDialog order={order} lineRows={lineRows} onClose={() => setFulfilling(false)} />}
    </div>
  );
}

function FulfilDialog({ order, lineRows, onClose }: { order: OrderRow; lineRows: OrderLineRow[]; onClose: () => void }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const [locationId, setLocationId] = useState('');
  const [date, setDate] = useState(toISODate());
  const [billNo, setBillNo] = useState('');
  const [boxes, setBoxes] = useState<Record<string, string>>(() => Object.fromEntries(lineRows.map((l) => [l.item_id ?? '', String(toNumber(l.pending_boxes))])));
  const loc = locationId || locations.data?.find((l) => l.is_active && l.kind === 'godown')?.id || locations.data?.[0]?.id || '';
  const sale = order.kind === 'sale';
  const run = useMutation({
    mutationFn: () => fulfilOrder(order.id ?? '', lineRows.map((l) => ({ item_id: l.item_id ?? '', boxes: toNumber(boxes[l.item_id ?? '']) })).filter((l) => l.boxes > 0), { location_id: loc, doc_date: date, bill_no: billNo || null }),
    onSuccess: async (docId) => { await qc.invalidateQueries({ queryKey: ['orders'] }); await qc.invalidateQueries({ queryKey: [sale ? 'invoices' : 'purchases'] }); toast({ title: sale ? 'Draft invoice created for this delivery' : 'Purchase bill recorded' }); navigate(sale ? `/invoices/${docId}` : `/purchases/${docId}`); },
    onError: (err) => toastError(err, 'Could not record'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader><DialogTitle>{sale ? 'Deliver against' : 'Receive against'} {order.order_no}</DialogTitle><DialogDescription>{sale ? 'Boxes going now become a draft invoice; the rest stays pending on the order.' : 'Boxes received now become a purchase bill and enter stock; the rest stays pending.'}</DialogDescription></DialogHeader>
        <div className="grid grid-cols-2 gap-3">
          <Field label={sale ? 'Stock leaves from' : 'Into location'} htmlFor="ff-loc"><NativeSelect id="ff-loc" value={loc} onChange={(e) => setLocationId(e.target.value)}>{(locations.data ?? []).filter((l) => l.is_active).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</NativeSelect></Field>
          <Field label="Date" htmlFor="ff-date"><Input id="ff-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
          {!sale && <Field label="Supplier bill no." htmlFor="ff-bill" className="col-span-2"><Input id="ff-bill" value={billNo} onChange={(e) => setBillNo(e.target.value)} /></Field>}
        </div>
        <Table>
          <TableHeader><TableRow><TableHead>Item</TableHead><TableHead className="text-right">Pending</TableHead><TableHead className="w-28 text-right">Boxes now</TableHead></TableRow></TableHeader>
          <TableBody>{lineRows.filter((l) => toNumber(l.pending_boxes) > 0).map((l) => <TableRow key={l.id ?? ''}><TableCell><span className="font-medium">{l.item_code}</span> {l.item_name}</TableCell><TableCell className="num">{qty(l.pending_boxes)}</TableCell><TableCell><Input type="number" step="0.001" min={0} max={toNumber(l.pending_boxes)} className="num h-8" aria-label={`Boxes for ${l.item_code}`} value={boxes[l.item_id ?? ''] ?? ''} onChange={(e) => setBoxes((b) => ({ ...b, [l.item_id ?? '']: e.target.value }))} /></TableCell></TableRow>)}</TableBody>
        </Table>
        <DialogFooter><Button variant="outline" onClick={onClose}>Back</Button><Button onClick={() => run.mutate()} disabled={run.isPending || !loc}>{run.isPending ? 'Saving…' : sale ? 'Create invoice' : 'Record purchase'}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
