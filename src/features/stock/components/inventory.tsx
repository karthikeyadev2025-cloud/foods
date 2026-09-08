import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Barcode, Download, Plus, Printer, Trash2 } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { searchItems, type ItemRow } from '@/features/items/api';
import { sectionsApi, stockLocationsApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { ean13Svg } from '@/lib/barcode';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, int, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { batchBalances, cancelStockCount, expiryReport, generateBarcodes, listBarcodes, listCounts, listTransfers, openStockCount, saveStockTransfer } from '../inventory-api';

// ------------------------------------------------------------------ batches & expiry
export function BatchesPanel() {
  const me = useMe();
  const orgId = me.data?.org_id ?? '';
  const [mode, setMode] = useState<'expiring' | 'all'>('expiring');
  const [days, setDays] = useState('30');
  const [item, setItem] = useState<ItemRow | null>(null);
  const expiring = useQuery({ queryKey: ['stock', 'expiry', orgId, days], queryFn: () => expiryReport(orgId, toNumber(days) || 30), enabled: Boolean(orgId) && mode === 'expiring' });
  const all = useQuery({ queryKey: ['stock', 'batches', orgId, item?.id], queryFn: () => batchBalances(orgId, item?.id ?? undefined), enabled: Boolean(orgId) && mode === 'all' });
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-end gap-2">
        <NativeSelect aria-label="View" className="h-8 w-44" value={mode} onChange={(e) => setMode(e.target.value as 'expiring' | 'all')}><option value="expiring">Expiring / expired</option><option value="all">All batches</option></NativeSelect>
        {mode === 'expiring' ? (
          <Field label="Within days" htmlFor="bt-days"><Input id="bt-days" type="number" className="num h-8 w-24" value={days} onChange={(e) => setDays(e.target.value)} /></Field>
        ) : (
          <Field label="Item" htmlFor="bt-item" className="w-72"><Combobox<ItemRow> id="bt-item" value={item} onChange={setItem} search={(q) => searchItems(q, { finishedOnly: true })} queryKey="items-finished" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code} — ${i.name}`} placeholder="All items…" eager /></Field>
        )}
        {mode === 'expiring' && (
          <Button size="sm" variant="outline" className="ml-auto" onClick={() => exportToExcel(`expiry-${days}d`, (expiring.data ?? []).map((r) => ({ Code: r.item_code, Item: r.item_name, Batch: r.batch_no, Made: dateDMY(r.mfg_date), Expiry: dateDMY(r.expiry_date), 'Days left': r.days_to_expiry, 'Boxes left': toNumber(r.remaining_boxes), 'Value at rate': toNumber(r.value_at_rate) })), 'Expiry')} disabled={!expiring.data?.length}><Download /> Excel</Button>
        )}
      </div>
      <p className="text-xs text-muted-foreground">A batch is born when production closes; expiry = making date + the item's shelf life (Add Product). Balances are FEFO: whatever left the item is taken from the earliest-expiring batch first. Opening and purchased stock sits outside batches.</p>
      {mode === 'expiring' ? (
        expiring.isLoading ? <Spinner /> : expiring.error ? <p role="alert" className="text-sm text-destructive">{expiring.error.message}</p> : !expiring.data?.length ? (
          <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">Nothing expiring within {days} days.</p>
        ) : (
          <div className="rounded-md border">
            <Table>
              <TableHeader><TableRow><TableHead>Code</TableHead><TableHead>Item</TableHead><TableHead>Batch</TableHead><TableHead>Made</TableHead><TableHead>Expiry</TableHead><TableHead className="text-right">Days left</TableHead><TableHead className="text-right">Boxes left</TableHead><TableHead className="text-right">Value</TableHead></TableRow></TableHeader>
              <TableBody>{expiring.data.map((r) => <TableRow key={r.batch_id} className={cn(r.is_expired && 'bg-red-50/60')}><TableCell className="font-medium">{r.item_code}</TableCell><TableCell>{r.item_name}</TableCell><TableCell>{r.batch_no}</TableCell><TableCell>{dateDMY(r.mfg_date)}</TableCell><TableCell>{dateDMY(r.expiry_date)}</TableCell><TableCell className={cn('num', r.is_expired && 'font-medium text-destructive')}>{r.is_expired ? `expired ${int(-toNumber(r.days_to_expiry))} d ago` : int(r.days_to_expiry)}</TableCell><TableCell className="num">{qty(r.remaining_boxes)}</TableCell><TableCell className="num">{amount(r.value_at_rate)}</TableCell></TableRow>)}</TableBody>
              <TableFooter><TableRow><TableCell colSpan={6} className="text-right">Total</TableCell><TableCell className="num">{qty(expiring.data.reduce((s, r) => s + toNumber(r.remaining_boxes), 0))}</TableCell><TableCell className="num">{amount(expiring.data.reduce((s, r) => s + toNumber(r.value_at_rate), 0))}</TableCell></TableRow></TableFooter>
            </Table>
          </div>
        )
      ) : all.isLoading ? <Spinner /> : !all.data?.length ? <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No batches yet — close a production batch to create one.</p> : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Code</TableHead><TableHead>Item</TableHead><TableHead>Batch</TableHead><TableHead>Made</TableHead><TableHead>Expiry</TableHead><TableHead className="text-right">Produced (bx)</TableHead><TableHead className="text-right">Gone (bx)</TableHead><TableHead className="text-right">Left (bx)</TableHead><TableHead>Status</TableHead></TableRow></TableHeader>
            <TableBody>{all.data.map((r) => <TableRow key={r.batch_id} className={cn(toNumber(r.remaining_base) === 0 && 'text-muted-foreground')}><TableCell className="font-medium">{r.item_code}</TableCell><TableCell>{r.item_name}</TableCell><TableCell>{r.batch_no}</TableCell><TableCell>{dateDMY(r.mfg_date)}</TableCell><TableCell>{r.expiry_date ? dateDMY(r.expiry_date) : '—'}</TableCell><TableCell className="num">{qty(toNumber(r.produced_base) / (r.units_per_box || 1))}</TableCell><TableCell className="num">{qty(toNumber(r.consumed_base) / (r.units_per_box || 1))}</TableCell><TableCell className="num font-medium">{qty(r.remaining_boxes)}</TableCell><TableCell>{r.is_expired ? <Badge variant="destructive">expired</Badge> : r.is_near_expiry ? <Badge variant="outline" className="border-amber-400 text-amber-800">this week</Badge> : toNumber(r.remaining_base) > 0 ? <Badge variant="secondary">on shelf</Badge> : <span className="text-xs">sold out</span>}</TableCell></TableRow>)}</TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ barcodes
export function BarcodesPanel() {
  const qc = useQueryClient();
  const perms = usePermissions();
  const rows = useQuery({ queryKey: ['stock', 'barcodes'], queryFn: listBarcodes });
  const [filter, setFilter] = useState('');
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const gen = useMutation({
    mutationFn: () => generateBarcodes(),
    onSuccess: async (n) => { toast({ title: n ? `${n} barcode${n === 1 ? '' : 's'} generated` : 'Every finished item already has its codes' }); await qc.invalidateQueries({ queryKey: ['stock', 'barcodes'] }); },
    onError: (e) => toastError(e, 'Could not generate'),
  });
  const list = useMemo(() => (rows.data ?? []).filter((r) => !filter || `${r.item_code} ${r.item_name} ${r.barcode}`.toLowerCase().includes(filter.toLowerCase())), [rows.data, filter]);
  const toggle = (id: string) => setPicked((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const ids = [...picked].join(',');
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Code, name, barcode…" aria-label="Filter" className="h-8 w-60" value={filter} onChange={(e) => setFilter(e.target.value)} />
        <Button size="sm" variant="outline" onClick={() => setPicked(new Set(list.map((r) => r.id ?? '')))} disabled={!list.length}>Select all shown</Button>
        <Button size="sm" variant="ghost" onClick={() => setPicked(new Set())} disabled={!picked.size}>Clear</Button>
        <span className="ml-auto flex gap-2">
          {perms.canEdit('items') && <Button size="sm" variant="outline" onClick={() => gen.mutate()} disabled={gen.isPending}><Barcode /> Generate missing</Button>}
          <Button asChild size="sm" disabled={!picked.size}><Link to={`/stock/labels?ids=${ids}`}><Printer /> Print {picked.size ? `${picked.size} label${picked.size === 1 ? '' : 's'}` : 'labels'}</Link></Button>
        </span>
      </div>
      <p className="text-xs text-muted-foreground">Two EAN-13 codes per finished item: one for a box, one for a single jar / pack. Scan either into the invoice CODE box — a box code adds one box, a unit code adds one jar.</p>
      {rows.isLoading ? <Spinner /> : !list.length ? <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No barcodes yet. Generate them, then print labels.</p> : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead className="w-8" /><TableHead>Code</TableHead><TableHead>Item</TableHead><TableHead>Level</TableHead><TableHead>Barcode</TableHead><TableHead className="text-right">Rate</TableHead></TableRow></TableHeader>
            <TableBody>{list.map((r) => <TableRow key={r.id ?? ''} className="cursor-pointer" onClick={() => toggle(r.id ?? '')}><TableCell><Checkbox checked={picked.has(r.id ?? '')} onChange={() => toggle(r.id ?? '')} aria-label={`Select ${r.barcode}`} /></TableCell><TableCell className="font-medium">{r.item_code}</TableCell><TableCell>{r.item_name}</TableCell><TableCell><Badge variant="outline">{r.level === 'box' ? `box · ${r.units_per_box} ${r.uom_code ?? ''}`.trim() : r.uom_code ?? 'unit'}</Badge></TableCell><TableCell className="font-mono">{r.barcode}</TableCell><TableCell className="num">{r.level === 'box' ? amount(toNumber(r.unit_rate) * toNumber(r.units_per_box)) : amount(r.unit_rate)}</TableCell></TableRow>)}</TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}

/** Label sheet: 3 columns on A4, one label per selected barcode. */
export function LabelsPrintPage() {
  const me = useMe();
  const ids = new Set((new URLSearchParams(window.location.search).get('ids') ?? '').split(',').filter(Boolean));
  const rows = useQuery({ queryKey: ['stock', 'barcodes'], queryFn: listBarcodes });
  const [copies, setCopies] = useState('1');
  useEffect(() => { document.title = 'Labels'; }, []);
  if (rows.isLoading) return <Spinner label="Preparing labels…" full />;
  const labels = (rows.data ?? []).filter((r) => ids.has(r.id ?? ''));
  const n = Math.max(1, Math.min(50, toNumber(copies) || 1));
  return (
    <div className="min-h-screen bg-neutral-200 print:bg-white">
      <div className="no-print flex items-center justify-between gap-2 border-b bg-card px-4 py-2 text-sm">
        <Button asChild variant="ghost" size="sm"><Link to="/stock/barcodes">← Barcodes</Link></Button>
        <span className="flex items-center gap-2">Copies each <Input type="number" min={1} max={50} className="num h-8 w-20" value={copies} onChange={(e) => setCopies(e.target.value)} /><Button size="sm" onClick={() => window.print()}>Print {labels.length * n} labels</Button></span>
      </div>
      <div className="label-sheet mx-auto my-4 grid grid-cols-3 gap-2 bg-white p-4 print:my-0 print:p-0">
        {labels.flatMap((r) => Array.from({ length: n }).map((_, i) => (
          <div key={`${r.id}-${i}`} className="label flex flex-col items-center justify-between border border-dashed border-neutral-300 p-2 text-center text-black print:border-0">
            <div className="text-[10px] font-semibold uppercase">{me.data?.org_name ?? 'JYOTHI FOODS'}</div>
            <div className="line-clamp-2 text-[11px] font-bold leading-tight">{r.item_name}</div>
            <div className="text-[10px]">{r.item_code} · {r.level === 'box' ? `BOX of ${r.units_per_box}` : (r.uom_code ?? 'UNIT')}{toNumber(r.mrp_per_piece) ? ` · MRP ₹${amount(r.mrp_per_piece)}/pc` : ''}</div>
            <div dangerouslySetInnerHTML={{ __html: ean13Svg(r.barcode ?? '', { moduleWidth: 1.4, height: 34 }) }} />
          </div>
        )))}
      </div>
      <style>{`.label-sheet { width: 210mm; } .label { height: 36mm; break-inside: avoid; } @page { size: A4; margin: 8mm; } @media print { .label-sheet { width: auto; gap: 2mm; } body { background: white; } }`}</style>
    </div>
  );
}

// ------------------------------------------------------------------ transfers
interface TLine { key: number; item: ItemRow | null; boxes: string }

export function TransfersPanel() {
  const perms = usePermissions();
  const rows = useQuery({ queryKey: ['stock', 'transfers'], queryFn: listTransfers });
  const [creating, setCreating] = useState(false);
  const list = rows.data ?? [];
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <p className="text-sm text-muted-foreground">Godown to godown (or shop). Two ledger rows per line, one out and one in, with a printable transfer note.</p>
        <span className="ml-auto flex gap-2">
          <Button size="sm" variant="outline" onClick={() => exportToExcel('stock-transfers', list.map((t) => ({ 'Transfer no.': t.transfer_no, Date: dateDMY(t.txn_date), From: t.from_name, To: t.to_name, Boxes: toNumber(t.total_boxes), Lines: toNumber(t.line_count), Notes: t.notes, By: t.created_by_name })), 'Transfers')} disabled={!list.length}><Download /> Excel</Button>
          {perms.canEdit('stock') && <Button size="sm" onClick={() => setCreating(true)}><Plus /> New transfer</Button>}
        </span>
      </div>
      {rows.isLoading ? <Spinner /> : !list.length ? <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No transfers yet.</p> : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>No.</TableHead><TableHead>Date</TableHead><TableHead>From</TableHead><TableHead>To</TableHead><TableHead className="text-right">Lines</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead>Notes</TableHead><TableHead>By</TableHead><TableHead /></TableRow></TableHeader>
            <TableBody>{list.map((t) => <TableRow key={t.id ?? ''}><TableCell className="font-medium">{t.transfer_no}</TableCell><TableCell>{dateDMY(t.txn_date)}</TableCell><TableCell>{t.from_name}</TableCell><TableCell>{t.to_name}</TableCell><TableCell className="num">{int(t.line_count)}</TableCell><TableCell className="num">{qty(t.total_boxes)}</TableCell><TableCell className="text-muted-foreground">{t.notes}</TableCell><TableCell className="text-xs text-muted-foreground">{t.created_by_name}</TableCell><TableCell className="text-right"><Button asChild size="sm" variant="outline"><Link to={`/stock/transfers/${t.id}/print`}><Printer /> Note</Link></Button></TableCell></TableRow>)}</TableBody>
          </Table>
        </div>
      )}
      {creating && <TransferDialog onClose={() => setCreating(false)} />}
    </div>
  );
}

function TransferDialog({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const locs = (locations.data ?? []).filter((l) => l.is_active);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [date, setDate] = useState(toISODate());
  const [notes, setNotes] = useState('');
  const [lines, setLines] = useState<TLine[]>([{ key: 1, item: null, boxes: '' }]);
  useEffect(() => { if (locs.length && !from) { setFrom(locs.find((l) => l.kind === 'godown')?.id ?? locs[0]?.id ?? ''); setTo(locs.find((l) => l.id !== (locs.find((x) => x.kind === 'godown')?.id ?? locs[0]?.id))?.id ?? ''); } }, [locs, from]);
  const save = useMutation({
    mutationFn: () => {
      const ls = lines.filter((l) => l.item?.id && toNumber(l.boxes) > 0);
      if (!ls.length) throw new Error('Add at least one line');
      return saveStockTransfer({ from_location: from, to_location: to, txn_date: date, notes: notes || null }, ls.map((l) => ({ item_id: l.item?.id ?? '', boxes: toNumber(l.boxes) })));
    },
    onSuccess: async (id) => { toast({ title: 'Transfer posted' }); await qc.invalidateQueries({ queryKey: ['stock'] }); onClose(); navigate(`/stock/transfers/${id}/print`); },
    onError: (e) => toastError(e, 'Could not transfer'),
  });
  const update = (key: number, patch: Partial<TLine>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-xl">
        <DialogHeader><DialogTitle>Godown transfer</DialogTitle><DialogDescription>Stock leaves one location and arrives at the other the moment you save.</DialogDescription></DialogHeader>
        <div className="grid grid-cols-3 gap-3">
          <Field label="From" htmlFor="tr-from"><NativeSelect id="tr-from" value={from} onChange={(e) => setFrom(e.target.value)}>{locs.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</NativeSelect></Field>
          <Field label="To" htmlFor="tr-to"><NativeSelect id="tr-to" value={to} onChange={(e) => setTo(e.target.value)}>{locs.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</NativeSelect></Field>
          <Field label="Date" htmlFor="tr-date"><Input id="tr-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
          <Field label="Notes" htmlFor="tr-notes" className="col-span-3"><Input id="tr-notes" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
        </div>
        <Table>
          <TableHeader><TableRow><TableHead>Item</TableHead><TableHead className="w-28 text-right">Boxes</TableHead><TableHead className="w-8" /></TableRow></TableHeader>
          <TableBody>{lines.map((l) => <TableRow key={l.key}><TableCell><Combobox<ItemRow> value={l.item} onChange={(it) => update(l.key, { item: it })} search={(q) => searchItems(q, { finishedOnly: true })} queryKey="items-finished" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code} — ${i.name}`} renderOption={(i) => <span><span className="font-medium">{i.item_code}</span> {i.name}<span className="text-muted-foreground"> · stock {qty(toNumber(i.stock_base) / (i.units_per_box || 1))} bx</span></span>} placeholder="Code or name…" aria-label="Item" /></TableCell><TableCell><Input type="number" step="0.001" className="num h-8" aria-label="Boxes" value={l.boxes} onChange={(e) => update(l.key, { boxes: e.target.value })} /></TableCell><TableCell><Button size="sm" variant="ghost" aria-label="Remove" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} disabled={lines.length <= 1}><Trash2 /></Button></TableCell></TableRow>)}</TableBody>
        </Table>
        <Button type="button" size="sm" variant="outline" onClick={() => setLines((ls) => [...ls, { key: Date.now(), item: null, boxes: '' }])}><Plus /> Line</Button>
        <DialogFooter><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={() => save.mutate()} disabled={save.isPending || !from || !to || from === to}>{save.isPending ? 'Posting…' : 'Transfer'}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ------------------------------------------------------------------ physical counts
export function CountsPanel() {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const perms = usePermissions();
  const rows = useQuery({ queryKey: ['stock', 'counts'], queryFn: listCounts });
  const [opening, setOpening] = useState(false);
  const cancel = useMutation({
    mutationFn: (id: string) => cancelStockCount(id),
    onSuccess: async () => { toast({ title: 'Count cancelled' }); await qc.invalidateQueries({ queryKey: ['stock', 'counts'] }); },
    onError: (e) => toastError(e, 'Could not cancel'),
  });
  const list = rows.data ?? [];
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <p className="max-w-2xl text-sm text-muted-foreground">Open a sheet for one location (and optionally one section), print it, count, type the boxes, post. Each difference against the live figure becomes an adjustment row — the ledger is never edited.</p>
        {perms.canEdit('stock') && <Button size="sm" className="ml-auto" onClick={() => setOpening(true)}><Plus /> New count</Button>}
      </div>
      {rows.isLoading ? <Spinner /> : !list.length ? <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No counts yet.</p> : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>No.</TableHead><TableHead>Date</TableHead><TableHead>Location</TableHead><TableHead>Section</TableHead><TableHead className="text-right">Items</TableHead><TableHead className="text-right">Counted</TableHead><TableHead className="text-right">Differences</TableHead><TableHead>Status</TableHead><TableHead>By</TableHead><TableHead /></TableRow></TableHeader>
            <TableBody>{list.map((c) => <TableRow key={c.id ?? ''} className="cursor-pointer" tabIndex={0} onClick={() => navigate(`/stock/counts/${c.id}`)} onKeyDown={(ev) => ev.key === 'Enter' && navigate(`/stock/counts/${c.id}`)}><TableCell className="font-medium">{c.count_no}</TableCell><TableCell>{dateDMY(c.count_date)}</TableCell><TableCell>{c.location_name}</TableCell><TableCell className="text-muted-foreground">{c.section_name ?? 'All'}</TableCell><TableCell className="num">{int(c.line_count)}</TableCell><TableCell className="num">{int(c.counted_count)}</TableCell><TableCell className="num">{int(c.variance_count)}</TableCell><TableCell><Badge variant={c.status === 'open' ? 'default' : c.status === 'posted' ? 'secondary' : 'destructive'}>{c.status}</Badge></TableCell><TableCell className="text-xs text-muted-foreground">{c.status === 'posted' ? c.posted_by_name : c.created_by_name}</TableCell><TableCell className="text-right" onClick={(ev) => ev.stopPropagation()}>{perms.canEdit('stock') && c.status === 'open' && <Button size="sm" variant="ghost" className="text-destructive" onClick={() => cancel.mutate(c.id ?? '')}>Cancel</Button>}</TableCell></TableRow>)}</TableBody>
          </Table>
        </div>
      )}
      {opening && <OpenCountDialog onClose={() => setOpening(false)} />}
    </div>
  );
}

function OpenCountDialog({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const sections = useQuery({ queryKey: ['setup', 'sections'], queryFn: sectionsApi.list });
  const [locationId, setLocationId] = useState('');
  const [sectionId, setSectionId] = useState('');
  const [date, setDate] = useState(toISODate());
  const [notes, setNotes] = useState('');
  const loc = locationId || locations.data?.find((l) => l.is_active && l.kind === 'godown')?.id || locations.data?.[0]?.id || '';
  const open = useMutation({
    mutationFn: () => openStockCount(loc, date, sectionId || undefined, notes || undefined),
    onSuccess: async (id) => { await qc.invalidateQueries({ queryKey: ['stock', 'counts'] }); onClose(); navigate(`/stock/counts/${id}`); },
    onError: (e) => toastError(e, 'Could not open the count'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogHeader><DialogTitle>New stock count</DialogTitle><DialogDescription>The system figure is frozen on the sheet; posting compares your count with the live figure so sales made meanwhile are not double counted.</DialogDescription></DialogHeader>
        <Field label="Location" htmlFor="oc-loc"><NativeSelect id="oc-loc" value={loc} onChange={(e) => setLocationId(e.target.value)}>{(locations.data ?? []).filter((l) => l.is_active).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</NativeSelect></Field>
        <Field label="Section" htmlFor="oc-sec"><NativeSelect id="oc-sec" value={sectionId} onChange={(e) => setSectionId(e.target.value)}><option value="">All sections</option>{(sections.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.code ? `${s.code} ` : ''}{s.name}</option>)}</NativeSelect></Field>
        <Field label="Count date" htmlFor="oc-date"><Input id="oc-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
        <Field label="Notes" htmlFor="oc-notes"><Input id="oc-notes" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="month end" /></Field>
        <DialogFooter><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={() => open.mutate()} disabled={open.isPending || !loc}>{open.isPending ? 'Opening…' : 'Open sheet'}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
