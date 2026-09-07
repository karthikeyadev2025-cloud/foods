import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Printer, Trash2 } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
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
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { listInvoices } from '@/features/invoices/api';
import { searchItems, type ItemRow } from '@/features/items/api';
import { stockLocationsApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { amount, dateDMY, int, qty, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { TRIP_STATUSES, getTrip, setTripStatus, settleTrip, tripLoadingSheet, tripSettlement, tripTone, vanLoad, type TripStatus } from '../trips-api';
import { TripsLink } from './TripsPage';

interface LoadDraft { key: string; item_id: string; item_code: string; item_name: string; units_per_box: number; boxes: number }
let seq = 0;

export function TripDetailPage() {
  const { id } = useParams();
  const perms = usePermissions();
  const queryClient = useQueryClient();
  const trip = useQuery({ queryKey: ['trips', 'one', id], queryFn: () => getTrip(id ?? ''), enabled: Boolean(id) });
  const sheet = useQuery({ queryKey: ['trips', 'sheet', id], queryFn: () => tripLoadingSheet(id ?? ''), enabled: Boolean(id) });
  const settlement = useQuery({ queryKey: ['trips', 'settlement', id], queryFn: () => tripSettlement(id ?? ''), enabled: Boolean(id) });
  const invoices = useQuery({ queryKey: ['invoices', 'trip', id], queryFn: () => listInvoices({ page: 1, pageSize: 100, search: '' }), enabled: false });
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const godowns = (locations.data ?? []).filter((l) => l.is_active && l.kind !== 'vehicle');

  const [fromLoc, setFromLoc] = useState('');
  const [lines, setLines] = useState<LoadDraft[]>([]);
  const [entryItem, setEntryItem] = useState<ItemRow | null>(null);
  const [entryBoxes, setEntryBoxes] = useState('');
  const [settleOpen, setSettleOpen] = useState(false);
  const boxesRef = useRef<HTMLInputElement>(null);
  const codeWrap = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (godowns.length && !fromLoc) setFromLoc(godowns.find((g) => g.kind === 'godown')?.id ?? godowns[0]?.id ?? '');
  }, [godowns, fromLoc]);

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: ['trips'] });
    await queryClient.invalidateQueries({ queryKey: ['stock'] });
    await queryClient.invalidateQueries({ queryKey: ['items'] });
  };

  const load = useMutation({
    mutationFn: () => {
      if (!fromLoc) throw new Error('Choose the godown to load from');
      if (!lines.length) throw new Error('Add at least one line');
      return vanLoad(id ?? '', fromLoc, lines.map((l) => ({ item_id: l.item_id, boxes: l.boxes })));
    },
    onSuccess: async () => {
      await invalidate();
      setLines([]);
      toast({ title: 'Loaded — stock moved to the van' });
    },
    onError: (err) => toastError(err, 'Could not load the van'),
  });
  const status = useMutation({
    mutationFn: (s: TripStatus) => setTripStatus(id ?? '', s),
    onSuccess: async (_d, s) => {
      await invalidate();
      toast({ title: `Trip ${TRIP_STATUSES.find((x) => x.value === s)?.label.toLowerCase()}` });
    },
    onError: (err) => toastError(err, 'Could not change the trip status'),
  });

  const addEntry = () => {
    const b = toNumber(entryBoxes);
    if (!entryItem?.id || b <= 0) return;
    setLines((p) => [...p, { key: `t${++seq}`, item_id: entryItem.id ?? '', item_code: entryItem.item_code ?? '', item_name: entryItem.name ?? '', units_per_box: entryItem.units_per_box ?? 0, boxes: b }]);
    setEntryItem(null);
    setEntryBoxes('');
    setTimeout(() => codeWrap.current?.querySelector('input')?.focus(), 0);
  };

  if (trip.isLoading) return <Spinner label="Loading trip…" />;
  if (!trip.data) return <p role="alert" className="text-sm text-destructive">Trip not found.</p>;
  const t = trip.data;
  const st = (t.status ?? 'planned') as TripStatus;
  const canEdit = perms.canEdit('vehicles');
  const canLoad = canEdit && (st === 'planned' || st === 'loaded');
  const rows = settlement.data ?? [];
  const sum = (k: 'loaded' | 'sold' | 'returned' | 'gap' | 'sale_value') => rows.reduce((s, r) => s + toNumber(r[k]), 0);
  void invoices;

  return (
    <div className="space-y-4">
      <PageHeader
        title={`${t.vehicle_number} · ${dateDMY(t.trip_date)}`}
        description={`${t.driver_name ? `Driver ${t.driver_name}` : 'No driver'}${t.route_name ? ` · ${t.route_name}` : ''} · van stock location: ${t.van_location_name ?? '—'}`}
        actions={
          <>
            <Badge variant={tripTone[st]}>{TRIP_STATUSES.find((s) => s.value === st)?.label}</Badge>
            {(st === 'loaded' || st === 'dispatched' || st === 'settled') && (
              <Button asChild variant="outline" size="sm"><Link to={`/vehicles/trips/${t.id}/print`}><Printer /> Loading sheet</Link></Button>
            )}
            {canEdit && st === 'loaded' && <Button size="sm" onClick={() => status.mutate('dispatched')} disabled={status.isPending}>Dispatch</Button>}
            {canEdit && (st === 'loaded' || st === 'dispatched') && <Button size="sm" variant="secondary" onClick={() => setSettleOpen(true)}>Settle trip</Button>}
            {canEdit && st === 'planned' && <Button size="sm" variant="ghost" className="text-destructive" onClick={() => status.mutate('cancelled')} disabled={status.isPending}>Cancel trip</Button>}
            <TripsLink />
          </>
        }
      />

      {canLoad && (
        <Card>
          <CardHeader className="pb-2"><CardTitle className="text-base">Load the van</CardTitle></CardHeader>
          <CardContent className="space-y-3">
            <Field label="From godown" htmlFor="ld-from" className="max-w-xs">
              <NativeSelect id="ld-from" value={fromLoc} onChange={(e) => setFromLoc(e.target.value)}>
                {godowns.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
              </NativeSelect>
            </Field>
            <div className="rounded-md border">
              <Table>
                <TableHeader><TableRow><TableHead className="w-40">CODE</TableHead><TableHead>Item</TableHead><TableHead className="w-20 text-right">Jars</TableHead><TableHead className="w-28 text-right">Boxes</TableHead><TableHead className="w-24 text-right">Units</TableHead><TableHead className="w-10" /></TableRow></TableHeader>
                <TableBody>
                  {lines.map((l) => (
                    <TableRow key={l.key}>
                      <TableCell className="font-medium">{l.item_code}</TableCell><TableCell>{l.item_name}</TableCell><TableCell className="num text-muted-foreground">{int(l.units_per_box)}</TableCell>
                      <TableCell className="num"><Input type="number" step="0.001" className="num h-8" aria-label={`Boxes ${l.item_code}`} value={l.boxes} onChange={(e) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, boxes: toNumber(e.target.value) } : x))} /></TableCell>
                      <TableCell className="num text-muted-foreground">{qty(l.boxes * l.units_per_box)}</TableCell>
                      <TableCell><Button type="button" variant="ghost" size="icon" aria-label={`Remove ${l.item_code}`} onClick={() => setLines((p) => p.filter((x) => x.key !== l.key))}><Trash2 className="text-destructive" /></Button></TableCell>
                    </TableRow>
                  ))}
                  <TableRow className="bg-muted/30">
                    <TableCell>
                      <div ref={codeWrap}>
                        <Combobox<ItemRow> value={entryItem} onChange={setEntryItem} search={(q) => searchItems(q, { finishedOnly: true })} queryKey="items" getKey={(i) => i.id ?? ''} getLabel={(i) => i.item_code ?? ''} renderOption={(i) => <span><span className="font-medium">{i.item_code}</span> {i.name}<span className="text-muted-foreground"> · stock {qty(toNumber(i.stock_base) / (i.units_per_box || 1))} bx</span></span>} placeholder="CODE" aria-label="Item code" onPicked={() => setTimeout(() => boxesRef.current?.focus(), 0)} />
                      </div>
                    </TableCell>
                    <TableCell className="text-muted-foreground">{entryItem?.name ?? ''}</TableCell>
                    <TableCell className="num text-muted-foreground">{entryItem ? int(entryItem.units_per_box) : ''}</TableCell>
                    <TableCell><Input ref={boxesRef} type="number" step="0.001" className="num h-8" aria-label="Boxes" value={entryBoxes} onChange={(e) => setEntryBoxes(e.target.value)} disabled={!entryItem} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); addEntry(); } }} /></TableCell>
                    <TableCell className="num text-muted-foreground">{entryItem && entryBoxes ? qty(toNumber(entryBoxes) * (entryItem.units_per_box ?? 0)) : ''}</TableCell>
                    <TableCell><Button type="button" size="sm" variant="secondary" onClick={addEntry} disabled={!entryItem}>Add</Button></TableCell>
                  </TableRow>
                </TableBody>
              </Table>
            </div>
            <div className="flex justify-end">
              <Button onClick={() => load.mutate()} disabled={load.isPending || !lines.length}>{load.isPending ? 'Loading…' : `Load ${qty(lines.reduce((s, l) => s + l.boxes, 0))} boxes onto the van`}</Button>
            </div>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader className="pb-2"><CardTitle className="text-base">On the van (loading sheet)</CardTitle></CardHeader>
          <CardContent>
            {sheet.isLoading ? <Spinner /> : !sheet.data?.length ? <p className="text-sm text-muted-foreground">Nothing loaded yet.</p> : (
              <Table>
                <TableHeader><TableRow><TableHead>CODE</TableHead><TableHead>Item</TableHead><TableHead>Pack</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead className="text-right">Units</TableHead></TableRow></TableHeader>
                <TableBody>{sheet.data.map((r) => <TableRow key={r.item_id ?? ''}><TableCell className="font-medium">{r.item_code}</TableCell><TableCell>{r.item_name}</TableCell><TableCell className="text-muted-foreground">{r.pack ?? '—'}</TableCell><TableCell className="num">{qty(r.boxes)}</TableCell><TableCell className="num text-muted-foreground">{qty(r.units)}</TableCell></TableRow>)}</TableBody>
                <TableFooter><TableRow><TableCell colSpan={3} className="text-right">Total</TableCell><TableCell className="num">{qty(sheet.data.reduce((s, r) => s + toNumber(r.boxes), 0))}</TableCell><TableCell /></TableRow></TableFooter>
              </Table>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2"><CardTitle className="text-base">Settlement — loaded vs sold vs returned</CardTitle></CardHeader>
          <CardContent className="space-y-3">
            {settlement.isLoading ? <Spinner /> : rows.length === 0 ? <p className="text-sm text-muted-foreground">Nothing to settle yet.</p> : (
              <Table>
                <TableHeader><TableRow><TableHead>CODE</TableHead><TableHead className="text-right">Loaded</TableHead><TableHead className="text-right">Sold</TableHead><TableHead className="text-right">Returned</TableHead><TableHead className="text-right">Gap</TableHead></TableRow></TableHeader>
                <TableBody>
                  {rows.map((r) => (
                    <TableRow key={r.item_id ?? ''}>
                      <TableCell className="font-medium" title={r.item_name ?? ''}>{r.item_code}</TableCell>
                      <TableCell className="num">{qty(r.loaded)}</TableCell><TableCell className="num">{qty(r.sold)}</TableCell><TableCell className="num">{qty(r.returned)}</TableCell>
                      <TableCell className={cn('num font-medium', toNumber(r.gap) !== 0 && 'text-destructive')}>{qty(r.gap)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
                <TableFooter>
                  <TableRow><TableCell className="text-right">Boxes</TableCell><TableCell className="num">{qty(sum('loaded'))}</TableCell><TableCell className="num">{qty(sum('sold'))}</TableCell><TableCell className="num">{qty(sum('returned'))}</TableCell><TableCell className={cn('num', sum('gap') !== 0 && 'text-destructive')}>{qty(sum('gap'))}</TableCell></TableRow>
                </TableFooter>
              </Table>
            )}
            <div className="grid grid-cols-3 gap-2 text-sm">
              <Stat label="Sold (invoices)" value={amount(t.sold_value)} sub={`${int(t.invoice_count)} bills`} />
              <Stat label="Collected on trip" value={amount(t.collected)} />
              <Stat label="Sold − collected" value={amount(toNumber(t.sold_value) - toNumber(t.collected))} tone={toNumber(t.sold_value) - toNumber(t.collected) > 0 ? 'warn' : undefined} />
            </div>
            <p className="text-xs text-muted-foreground">
              Gap = loaded − sold − returned. It should be 0 after settlement; anything else is stock unaccounted for the same evening.
              {st === 'settled' && ` Closing km ${t.closing_km ?? '—'} · expenses ${amount(t.expenses)}.`}
            </p>
          </CardContent>
        </Card>
      </div>

      {settleOpen && (
        <SettleDialog tripId={t.id ?? ''} godowns={godowns} leftBoxes={sum('gap')} onClose={() => setSettleOpen(false)} onDone={invalidate} />
      )}
    </div>
  );
}

function Stat({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: 'warn' }) {
  return (
    <div className={cn('rounded-md border p-2', tone === 'warn' && 'border-amber-300 bg-amber-50')}>
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="font-semibold tabular-nums">{value}</div>
      {sub && <div className="text-xs text-muted-foreground">{sub}</div>}
    </div>
  );
}

function SettleDialog({ tripId, godowns, leftBoxes, onClose, onDone }: { tripId: string; godowns: { id: string; name: string; kind: string }[]; leftBoxes: number; onClose: () => void; onDone: () => Promise<void> }) {
  const [toLoc, setToLoc] = useState(godowns.find((g) => g.kind === 'godown')?.id ?? godowns[0]?.id ?? '');
  const [km, setKm] = useState('');
  const [expenses, setExpenses] = useState('');
  const [notes, setNotes] = useState('');
  const settle = useMutation({
    mutationFn: () => {
      if (!toLoc) throw new Error('Choose the godown the unsold stock goes back to');
      return settleTrip(tripId, toLoc, km ? toNumber(km) : null, expenses ? toNumber(expenses) : null, notes || null);
    },
    onSuccess: async () => {
      await onDone();
      toast({ title: 'Trip settled — unsold stock is back in the godown' });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not settle the trip'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Settle trip</DialogTitle>
          <DialogDescription>Everything still on the van ({qty(leftBoxes)} boxes by the settlement table) is unloaded to the godown you choose, then the trip closes.</DialogDescription>
        </DialogHeader>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Unload to" htmlFor="st-to" className="col-span-2">
            <NativeSelect id="st-to" value={toLoc} onChange={(e) => setToLoc(e.target.value)}>{godowns.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}</NativeSelect>
          </Field>
          <Field label="Closing km" htmlFor="st-km"><Input id="st-km" type="number" step="0.1" className="num" value={km} onChange={(e) => setKm(e.target.value)} /></Field>
          <Field label="Trip expenses (₹)" htmlFor="st-exp"><Input id="st-exp" type="number" step="0.01" className="num" value={expenses} onChange={(e) => setExpenses(e.target.value)} /></Field>
          <Field label="Notes" htmlFor="st-notes" className="col-span-2"><Input id="st-notes" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={() => settle.mutate()} disabled={settle.isPending}>{settle.isPending ? 'Settling…' : 'Settle'}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
