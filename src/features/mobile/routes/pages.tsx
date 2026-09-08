import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Camera, Check, ChevronRight, Phone, Plus, Receipt, Trash2 } from 'lucide-react';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { saveInvoice, setInvoiceStatus } from '@/features/invoices/api';
import { effectiveUnitRate, searchItems, type ItemRow } from '@/features/items/api';
import { saveReceipt } from '@/features/receipts/api';
import { receiptModesApi } from '@/features/setup/api';
import { tripSettlement, tripTone, type TripRow } from '@/features/vehicles/trips-api';
import { toast, toastError } from '@/hooks/use-toast';
import { amount, dateDMY, int, qty, round, toISODate, toNumber } from '@/lib/format';
import { OfflineQueuedError } from '@/lib/offline';
import { cn } from '@/lib/utils';
import { markDelivered, proofUrl, tripInvoicesFor, tripStops, uploadProof, type StopRow, type TripInvoice } from '../api';
import { useActiveTrip } from '../hooks';

const STOPS_KEY = (trip: string) => ['mobile', 'stops', trip] as const;

function Tile({ label, value, tone }: { label: string; value: string; tone?: 'good' | 'bad' }) {
  return (
    <div className="rounded-md border bg-card p-2">
      <div className="text-[11px] uppercase text-muted-foreground">{label}</div>
      <div className={cn('text-lg font-semibold tabular-nums', tone === 'good' && 'text-emerald-700', tone === 'bad' && 'text-destructive')}>{value}</div>
    </div>
  );
}

function NoTrip({ children }: { children?: React.ReactNode }) {
  return (
    <div className="space-y-3">
      <p className="rounded-md border border-dashed p-4 text-center text-sm text-muted-foreground">No trip on the road. The office creates the trip and loads the van; it shows here once it is loaded or dispatched.</p>
      {children}
    </div>
  );
}

// ---------------------------------------------------------------- trip
export function MTripPage() {
  const { trip, isDriver, openTrips, loading, error, pick } = useActiveTrip();
  const stops = useQuery({ queryKey: STOPS_KEY(trip?.id ?? ''), queryFn: () => tripStops(trip?.id ?? ''), enabled: Boolean(trip?.id) });
  if (loading) return <Spinner />;
  if (error) return <p role="alert" className="text-sm text-destructive">{error.message}</p>;
  if (!trip) {
    return (
      <NoTrip>
        {!isDriver && openTrips.length > 0 && (
          <div className="space-y-2">
            <div className="text-sm font-medium">Open trips — pick one</div>
            {openTrips.map((t) => <TripCard key={t.id ?? ''} trip={t} onClick={() => pick(t.id)} />)}
          </div>
        )}
      </NoTrip>
    );
  }
  const list = stops.data ?? [];
  const visited = list.filter((s) => toNumber(s.bills) > 0 || toNumber(s.collected) > 0).length;
  const pending = list.reduce((n, s) => n + (s.pending_delivery?.length ?? 0), 0);
  return (
    <div className="space-y-3">
      <TripCard trip={trip} />
      <div className="grid grid-cols-2 gap-2">
        <Tile label="Loaded" value={`${qty(trip.loaded_boxes)} boxes`} />
        <Tile label="Sold" value={amount(trip.sold_value)} tone="good" />
        <Tile label="Collected" value={amount(trip.collected)} tone="good" />
        <Tile label="Bills" value={int(trip.invoice_count)} />
        <Tile label="Stops visited" value={stops.isLoading ? '…' : `${visited} / ${list.length}`} />
        <Tile label="To deliver" value={stops.isLoading ? '…' : String(pending)} tone={pending ? 'bad' : undefined} />
      </div>
      <div className="grid grid-cols-2 gap-2">
        <Button asChild size="lg"><Link to="/m/stops">Stops <ChevronRight /></Link></Button>
        <Button asChild size="lg" variant="outline"><Link to="/m/stock">Van stock</Link></Button>
      </div>
      {!isDriver && openTrips.length > 1 && (
        <Button variant="ghost" size="sm" className="w-full" onClick={() => pick(null)}>Choose another trip</Button>
      )}
    </div>
  );
}

function TripCard({ trip, onClick }: { trip: TripRow; onClick?: () => void }) {
  const inner = (
    <>
      <div className="flex items-center justify-between">
        <div className="text-base font-semibold">{trip.route_name ?? 'No route'}</div>
        <Badge variant={tripTone[trip.status ?? 'planned']}>{trip.status === 'dispatched' ? 'on the road' : trip.status}</Badge>
      </div>
      <div className="text-sm text-muted-foreground">{trip.vehicle_number} · {trip.driver_name ?? 'no driver'} · {dateDMY(trip.trip_date)}</div>
    </>
  );
  if (onClick) return <button type="button" onClick={onClick} className="w-full rounded-md border bg-card p-3 text-left hover:bg-accent">{inner}</button>;
  return <div className="rounded-md border bg-card p-3">{inner}</div>;
}

// ---------------------------------------------------------------- stops
export function MStopsPage() {
  const { trip, loading } = useActiveTrip();
  const [q, setQ] = useState('');
  const stops = useQuery({ queryKey: STOPS_KEY(trip?.id ?? ''), queryFn: () => tripStops(trip?.id ?? ''), enabled: Boolean(trip?.id) });
  if (loading) return <Spinner />;
  if (!trip) return <NoTrip />;
  const s = q.trim().toLowerCase();
  const list = (stops.data ?? []).filter((r) => !s || (r.name ?? '').toLowerCase().includes(s) || (r.town ?? '').toLowerCase().includes(s) || (r.mobile1 ?? '').includes(s));
  return (
    <div className="space-y-2">
      <Input type="search" placeholder="Shop, town or mobile…" aria-label="Search stops" value={q} onChange={(e) => setQ(e.target.value)} />
      {stops.isLoading ? <Spinner /> : stops.error ? <p role="alert" className="text-sm text-destructive">{stops.error.message}</p> : !list.length ? (
        <p className="rounded-md border border-dashed p-4 text-center text-sm text-muted-foreground">{s ? 'No stop matches.' : 'No customers on this route yet.'}</p>
      ) : (
        <ul className="space-y-1.5">
          {list.map((r) => (
            <li key={r.customer_id ?? ''}>
              <Link to={`/m/stops/${r.customer_id}`} className="block rounded-md border bg-card p-3 hover:bg-accent">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <div className="truncate font-medium">{r.name}</div>
                    <div className="text-xs text-muted-foreground">{r.town}{!r.on_route && ' · off route'}</div>
                  </div>
                  <div className={cn('shrink-0 text-right text-sm tabular-nums', toNumber(r.outstanding) > 0 ? 'text-destructive' : 'text-muted-foreground')}>
                    {amount(r.outstanding)}
                    <div className="text-[10px] uppercase text-muted-foreground">due</div>
                  </div>
                </div>
                {(toNumber(r.bills) > 0 || toNumber(r.collected) > 0) && (
                  <div className="mt-1.5 flex flex-wrap gap-1 text-xs">
                    {toNumber(r.bills) > 0 && <Badge variant="secondary">billed {amount(r.billed)}</Badge>}
                    {toNumber(r.collected) > 0 && <Badge variant="secondary">collected {amount(r.collected)}</Badge>}
                    {(r.pending_delivery?.length ?? 0) > 0 ? <Badge variant="destructive">{r.pending_delivery?.length} to deliver</Badge> : toNumber(r.delivered) > 0 ? <Badge variant="outline"><Check className="mr-1 h-3 w-3" />delivered</Badge> : null}
                  </div>
                )}
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- one stop
export function MStopPage() {
  const { customerId = '' } = useParams();
  const { trip, loading } = useActiveTrip();
  const stops = useQuery({ queryKey: STOPS_KEY(trip?.id ?? ''), queryFn: () => tripStops(trip?.id ?? ''), enabled: Boolean(trip?.id) });
  const bills = useQuery({ queryKey: ['mobile', 'stop_bills', trip?.id, customerId], queryFn: () => tripInvoicesFor(trip?.id ?? '', customerId), enabled: Boolean(trip?.id && customerId) });
  const [delivering, setDelivering] = useState<TripInvoice | null>(null);
  if (loading) return <Spinner />;
  if (!trip) return <NoTrip />;
  const stop: StopRow | undefined = stops.data?.find((s) => s.customer_id === customerId);
  if (stops.isLoading) return <Spinner />;
  if (!stop) return <p className="text-sm text-muted-foreground">Stop not found on this trip.</p>;
  return (
    <div className="space-y-3">
      <div className="rounded-md border bg-card p-3">
        <div className="text-base font-semibold">{stop.name}</div>
        <div className="text-sm text-muted-foreground">{stop.town}{stop.address ? ` · ${stop.address}` : ''}</div>
        {stop.mobile1 && (
          <a href={`tel:${stop.mobile1}`} className="mt-1 inline-flex items-center gap-1 text-sm text-primary">
            <Phone className="h-4 w-4" /> {stop.mobile1}
          </a>
        )}
        <div className="mt-2 flex items-baseline justify-between">
          <span className="text-xs uppercase text-muted-foreground">Outstanding (live)</span>
          <span className={cn('text-xl font-semibold tabular-nums', toNumber(stop.outstanding) > 0 ? 'text-destructive' : '')}>{amount(stop.outstanding)}</span>
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <Button asChild size="lg"><Link to={`/m/stops/${customerId}/bill`}><Plus /> New bill</Link></Button>
        <Button asChild size="lg" variant="outline"><Link to={`/m/stops/${customerId}/collect`}><Receipt /> Collect</Link></Button>
      </div>
      <div>
        <div className="mb-1 text-sm font-medium">Today on this trip</div>
        {bills.isLoading ? <Spinner /> : !bills.data?.length ? (
          <p className="text-sm text-muted-foreground">No bill yet.{toNumber(stop.collected) > 0 && ` Collected ${amount(stop.collected)}.`}</p>
        ) : (
          <ul className="space-y-1.5">
            {bills.data.map((b) => (
              <li key={b.id ?? ''} className="flex items-center justify-between gap-2 rounded-md border bg-card p-3">
                <div>
                  <div className="font-medium">{b.invoice_no} · {amount(b.total)}</div>
                  <div className="text-xs text-muted-foreground">{qty(b.total_boxes)} boxes · {b.status}</div>
                </div>
                {b.status === 'confirmed' || b.status === 'dispatched' ? (
                  <Button size="sm" onClick={() => setDelivering(b)}><Camera /> Deliver</Button>
                ) : b.status === 'delivered' ? (
                  <Badge variant="outline"><Check className="mr-1 h-3 w-3" />delivered</Badge>
                ) : (
                  <Badge variant="outline">{b.status}</Badge>
                )}
              </li>
            ))}
            {toNumber(stop.collected) > 0 && <li className="text-sm text-muted-foreground">Collected today: {amount(stop.collected)}</li>}
          </ul>
        )}
      </div>
      {delivering && <DeliverDialog invoice={delivering} onClose={() => setDelivering(null)} />}
    </div>
  );
}

function DeliverDialog({ invoice, onClose }: { invoice: TripInvoice; onClose: () => void }) {
  const qc = useQueryClient();
  const input = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState<File | null>(null);
  const [preview, setPreview] = useState<string | null>(null);
  const [receiver, setReceiver] = useState('');
  const [note, setNote] = useState('');
  useEffect(() => {
    if (!file) {
      setPreview(null);
      return;
    }
    const url = URL.createObjectURL(file);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [file]);
  const deliver = useMutation({
    mutationFn: async () => {
      const photo = file ? await uploadProof(invoice.id ?? '', file) : null;
      await markDelivered(invoice.id ?? '', { photo, receiver: receiver || null, note: note || null });
    },
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['mobile'] });
      await qc.invalidateQueries({ queryKey: ['invoices'] });
      await qc.invalidateQueries({ queryKey: ['trips'] });
      toast({ title: `${invoice.invoice_no} delivered` });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not mark the delivery'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && !deliver.isPending && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>Deliver {invoice.invoice_no}</DialogTitle>
          <DialogDescription>{amount(invoice.total)} · {qty(invoice.total_boxes)} boxes. A photo of the goods at the shop is the proof.</DialogDescription>
        </DialogHeader>
        <input ref={input} type="file" accept="image/*" capture="environment" className="hidden" aria-label="Take a photo" onChange={(ev) => setFile(ev.target.files?.[0] ?? null)} />
        <button type="button" onClick={() => input.current?.click()} className="flex h-40 w-full items-center justify-center overflow-hidden rounded-md border border-dashed bg-muted/40">
          {preview ? <img src={preview} alt="Delivery proof" className="h-full w-full object-cover" /> : <span className="flex items-center gap-2 text-sm text-muted-foreground"><Camera className="h-5 w-5" /> Take a photo</span>}
        </button>
        <Field label="Received by" htmlFor="dl-recv"><Input id="dl-recv" value={receiver} onChange={(e) => setReceiver(e.target.value)} placeholder="Name at the shop" /></Field>
        <Field label="Note" htmlFor="dl-note"><Input id="dl-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="Short of 1 box, shop closed…" /></Field>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={deliver.isPending}>Cancel</Button>
          <Button onClick={() => deliver.mutate()} disabled={deliver.isPending}>{deliver.isPending ? 'Saving…' : file ? 'Mark delivered' : 'Deliver without photo'}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** Small proof viewer for desktop screens; signed link fetched on demand. */
export function ProofLink({ path }: { path: string }) {
  const open = useMutation({ mutationFn: () => proofUrl(path), onSuccess: (url) => window.open(url, '_blank', 'noopener'), onError: (err) => toastError(err, 'Could not open the photo') });
  return <Button variant="link" size="sm" className="h-auto p-0" onClick={() => open.mutate()}>View delivery photo</Button>;
}

// ---------------------------------------------------------------- new bill
interface BillLine { key: string; item: ItemRow; boxes: number; rate: number }
let seq = 0;

export function MBillPage() {
  const { customerId = '' } = useParams();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { trip, loading } = useActiveTrip();
  const stops = useQuery({ queryKey: STOPS_KEY(trip?.id ?? ''), queryFn: () => tripStops(trip?.id ?? ''), enabled: Boolean(trip?.id) });
  const stop = stops.data?.find((s) => s.customer_id === customerId);
  const van = useQuery({ queryKey: ['trips', 'settlement', trip?.id], queryFn: () => tripSettlement(trip?.id ?? ''), enabled: Boolean(trip?.id) });
  const [item, setItem] = useState<ItemRow | null>(null);
  const [boxes, setBoxes] = useState('1');
  const [lines, setLines] = useState<BillLine[]>([]);
  const today = toISODate();
  const total = useMemo(() => round(lines.reduce((s, l) => s + l.boxes * toNumber(l.item.units_per_box) * l.rate, 0), 2), [lines]);
  const onHand = (itemId: string) => toNumber(van.data?.find((v) => v.item_id === itemId)?.gap);

  const add = useMutation({
    mutationFn: async () => {
      if (!item?.id) throw new Error('Pick an item');
      const b = toNumber(boxes);
      if (b <= 0) throw new Error('Boxes must be more than zero');
      const rate = await effectiveUnitRate(item.id, customerId, today);
      return { item, boxes: b, rate };
    },
    onSuccess: (l) => {
      setLines((ls) => {
        const i = ls.findIndex((x) => x.item.id === l.item.id);
        if (i >= 0) return ls.map((x, j) => (j === i ? { ...x, boxes: x.boxes + l.boxes } : x));
        return [...ls, { key: `l${++seq}`, ...l }];
      });
      setItem(null);
      setBoxes('1');
    },
    onError: (err) => toastError(err, 'Could not add the line'),
  });

  const save = useMutation({
    mutationFn: async () => {
      if (!trip?.id || !trip.van_location_id) throw new Error('No trip');
      if (!lines.length) throw new Error('Add at least one line');
      const id = await saveInvoice(
        { customer_id: customerId, invoice_date: today, location_id: trip.van_location_id, trip_id: trip.id, vehicle_id: trip.vehicle_id, freight: 0, discount: 0, round_off: 0 },
        lines.map((l) => ({ item_id: l.item.id ?? '', boxes: l.boxes, rate: l.rate })),
      );
      await setInvoiceStatus(id, 'confirmed');
      return id;
    },
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['mobile'] });
      await qc.invalidateQueries({ queryKey: ['trips'] });
      await qc.invalidateQueries({ queryKey: ['invoices'] });
      toast({ title: `Bill saved — ${amount(total)}` });
      navigate(`/m/stops/${customerId}`, { replace: true });
    },
    onError: (err) => {
      toastError(err, 'Could not save the bill');
      if (err instanceof OfflineQueuedError) navigate(`/m/stops/${customerId}`, { replace: true });
    },
  });

  if (loading) return <Spinner />;
  if (!trip) return <NoTrip />;
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-base font-semibold">New bill</div>
          <div className="text-sm text-muted-foreground">{stop?.name ?? '…'}</div>
        </div>
        <Button asChild variant="ghost" size="sm"><Link to={`/m/stops/${customerId}`}>Back</Link></Button>
      </div>
      <div className="rounded-md border bg-card p-3">
        <Field label="Item" htmlFor="mb-item">
          <Combobox<ItemRow> id="mb-item" value={item} onChange={setItem} search={(q) => searchItems(q, { finishedOnly: true })} queryKey="items" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code ?? ''} ${i.name ?? ''}`} renderOption={(i) => <span>{i.item_code} {i.name} <span className="text-muted-foreground">· van {qty(onHand(i.id ?? ''))}</span></span>} placeholder="Code or name, or scan" eager />
        </Field>
        <div className="mt-2 flex items-end gap-2">
          <Field label="Boxes" htmlFor="mb-boxes" className="w-28"><Input id="mb-boxes" type="number" inputMode="decimal" min={0} step="0.5" className="num" value={boxes} onChange={(e) => setBoxes(e.target.value)} /></Field>
          <Button type="button" onClick={() => add.mutate()} disabled={!item || add.isPending}><Plus /> Add</Button>
        </div>
        {item && <p className="mt-1 text-xs text-muted-foreground">{qty(item.units_per_box)} per box · van has {qty(onHand(item.id ?? ''))} boxes</p>}
      </div>
      {lines.length > 0 && (
        <ul className="divide-y rounded-md border bg-card">
          {lines.map((l) => (
            <li key={l.key} className="flex items-center gap-2 p-2">
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-medium">{l.item.item_code} {l.item.name}</div>
                <div className="text-xs text-muted-foreground">{qty(l.boxes)} × {qty(l.item.units_per_box)} @ {amount(l.rate)}</div>
              </div>
              <div className="text-sm font-medium tabular-nums">{amount(l.boxes * toNumber(l.item.units_per_box) * l.rate)}</div>
              <Button variant="ghost" size="icon" aria-label="Remove line" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))}><Trash2 /></Button>
            </li>
          ))}
        </ul>
      )}
      <div className="flex items-center justify-between rounded-md border bg-card p-3">
        <span className="text-sm">Total</span>
        <span className="text-xl font-semibold tabular-nums">{amount(total)}</span>
      </div>
      <Button size="lg" className="w-full" onClick={() => save.mutate()} disabled={!lines.length || save.isPending}>{save.isPending ? 'Saving…' : 'Save & confirm bill'}</Button>
      <p className="text-xs text-muted-foreground">Rates come from the customer's price list. Stock leaves the van on confirm. Offline, the bill waits in the outbox as a draft and the office confirms it.</p>
    </div>
  );
}

// ---------------------------------------------------------------- collect
export function MCollectPage() {
  const { customerId = '' } = useParams();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { trip, loading } = useActiveTrip();
  const stops = useQuery({ queryKey: STOPS_KEY(trip?.id ?? ''), queryFn: () => tripStops(trip?.id ?? ''), enabled: Boolean(trip?.id) });
  const stop = stops.data?.find((s) => s.customer_id === customerId);
  const modes = useQuery({ queryKey: ['setup', 'receipt_modes'], queryFn: receiptModesApi.list });
  const [modeId, setModeId] = useState('');
  const [amt, setAmt] = useState('');
  const [ref, setRef] = useState('');
  useEffect(() => {
    if (modes.data && !modeId) {
      const cash = modes.data.find((m) => m.is_active && m.code.toUpperCase() === 'CASH') ?? modes.data.find((m) => m.is_active);
      if (cash) setModeId(cash.id);
    }
  }, [modes.data, modeId]);
  const mode = modes.data?.find((m) => m.id === modeId);
  const save = useMutation({
    mutationFn: () => {
      const a = toNumber(amt);
      if (a <= 0) throw new Error('Enter the amount');
      if (!modeId) throw new Error('Pick how it was paid');
      if (mode?.needs_reference && !ref.trim()) throw new Error(`${mode.name} needs a reference (UTR / cheque no.)`);
      return saveReceipt(
        { customer_id: customerId, receipt_date: toISODate(), narration: null, vehicle_id: trip?.vehicle_id ?? null, trip_id: trip?.id ?? null },
        [{ mode_id: modeId, amount: a, reference: ref.trim() || null }],
        [],
      );
    },
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['mobile'] });
      await qc.invalidateQueries({ queryKey: ['trips'] });
      await qc.invalidateQueries({ queryKey: ['receipts'] });
      await qc.invalidateQueries({ queryKey: ['customers'] });
      toast({ title: `Collected ${amount(toNumber(amt))}` });
      navigate(`/m/stops/${customerId}`, { replace: true });
    },
    onError: (err) => {
      toastError(err, 'Could not save the receipt');
      if (err instanceof OfflineQueuedError) navigate(`/m/stops/${customerId}`, { replace: true });
    },
  });
  if (loading) return <Spinner />;
  if (!trip) return <NoTrip />;
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-base font-semibold">Collect</div>
          <div className="text-sm text-muted-foreground">{stop?.name ?? '…'} · due {amount(stop?.outstanding)}</div>
        </div>
        <Button asChild variant="ghost" size="sm"><Link to={`/m/stops/${customerId}`}>Back</Link></Button>
      </div>
      <div className="space-y-3 rounded-md border bg-card p-3">
        <Field label="Amount (₹)" htmlFor="mc-amt"><Input id="mc-amt" type="number" inputMode="decimal" min={0} step="0.01" className="num text-2xl" value={amt} onChange={(e) => setAmt(e.target.value)} autoFocus /></Field>
        <Field label="Paid by" htmlFor="mc-mode">
          <NativeSelect id="mc-mode" value={modeId} onChange={(e) => setModeId(e.target.value)}>
            {(modes.data ?? []).filter((m) => m.is_active && m.is_collection).map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
          </NativeSelect>
        </Field>
        {mode?.needs_reference && <Field label="Reference" htmlFor="mc-ref" help="UTR, cheque number or slip number."><Input id="mc-ref" value={ref} onChange={(e) => setRef(e.target.value)} /></Field>}
        {stop && toNumber(stop.outstanding) > 0 && (
          <Button type="button" variant="outline" size="sm" onClick={() => setAmt(String(toNumber(stop.outstanding)))}>Full amount {amount(stop.outstanding)}</Button>
        )}
      </div>
      <Button size="lg" className="w-full" onClick={() => save.mutate()} disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save receipt'}</Button>
      <p className="text-xs text-muted-foreground">Settled against the oldest bills first. Cheques go to Cheques in hand for the office to deposit.</p>
    </div>
  );
}

// ---------------------------------------------------------------- van stock
export function MStockPage() {
  const { trip, loading } = useActiveTrip();
  const van = useQuery({ queryKey: ['trips', 'settlement', trip?.id], queryFn: () => tripSettlement(trip?.id ?? ''), enabled: Boolean(trip?.id) });
  if (loading) return <Spinner />;
  if (!trip) return <NoTrip />;
  const rows = (van.data ?? []).filter((r) => toNumber(r.loaded) > 0 || toNumber(r.sold) > 0);
  return (
    <div className="space-y-2">
      <div className="text-base font-semibold">In the van — {trip.vehicle_number}</div>
      {van.isLoading ? <Spinner /> : !rows.length ? <p className="text-sm text-muted-foreground">Nothing loaded.</p> : (
        <ul className="divide-y rounded-md border bg-card">
          {rows.map((r) => (
            <li key={r.item_id ?? ''} className="flex items-center gap-2 p-2">
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-medium">{r.item_code} {r.item_name}</div>
                <div className="text-xs text-muted-foreground">loaded {qty(r.loaded)} · sold {qty(r.sold)}</div>
              </div>
              <div className={cn('text-lg font-semibold tabular-nums', toNumber(r.gap) <= 0 && 'text-muted-foreground')}>{qty(r.gap)}</div>
            </li>
          ))}
        </ul>
      )}
      <p className="text-xs text-muted-foreground">Boxes left = loaded − sold on this trip. The office settles the trip and takes the balance back into the godown.</p>
    </div>
  );
}
