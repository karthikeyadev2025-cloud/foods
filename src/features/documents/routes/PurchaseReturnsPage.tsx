import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Plus, Trash2 } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { searchItems, type ItemRow } from '@/features/items/api';
import { listPurchases, searchSuppliers, type SupplierRow } from '@/features/purchases/api';
import { stockLocationsApi } from '@/features/setup/api';
import { useDebounced } from '@/hooks/use-debounced';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, qty, round, toISODate, toNumber } from '@/lib/format';
import { getPurchaseReturnLines, listPurchaseReturns, savePurchaseReturn, type PurchaseReturnRow } from '../api';

interface Line { key: number; item: ItemRow | null; qty: string; rate: string }

export function PurchaseReturnsPage() {
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const debounced = useDebounced(search);
  const rows = useQuery({ queryKey: ['purchase_returns', debounced], queryFn: () => listPurchaseReturns(debounced) });
  const [creating, setCreating] = useState(false);
  const [open, setOpen] = useState<PurchaseReturnRow | null>(null);
  const list = rows.data ?? [];
  return (
    <div className="space-y-3">
      <PageHeader title="Purchase returns" description="Debit notes to suppliers: the goods leave stock and the supplier's payable comes down."
        actions={<><Button variant="outline" size="sm" onClick={() => exportToExcel('purchase-returns', list.map((r) => ({ 'Return no.': r.return_no, Date: dateDMY(r.return_date), Supplier: r.supplier_name, 'Against bill': r.bill_no, From: r.location_name, Total: toNumber(r.total), Notes: r.notes })), 'Purchase returns')} disabled={!list.length}><Download /> Excel</Button>{perms.canEdit('purchases') && <Button size="sm" onClick={() => setCreating(true)}><Plus /> New return</Button>}</>} />
      <Input type="search" placeholder="Return no., supplier, bill…" aria-label="Search" className="h-8 w-64" value={search} onChange={(e) => setSearch(e.target.value)} />
      {rows.isLoading ? <Spinner /> : rows.error ? <p role="alert" className="text-sm text-destructive">{rows.error.message}</p> : !list.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No purchase returns.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>No.</TableHead><TableHead>Date</TableHead><TableHead>Supplier</TableHead><TableHead>Against bill</TableHead><TableHead>From</TableHead><TableHead className="text-right">Total</TableHead><TableHead>Notes</TableHead></TableRow></TableHeader>
            <TableBody>{list.map((r) => <TableRow key={r.id ?? ''} className="cursor-pointer" tabIndex={0} onClick={() => setOpen(r)} onKeyDown={(ev) => ev.key === 'Enter' && setOpen(r)}><TableCell className="font-medium">{r.return_no}</TableCell><TableCell>{dateDMY(r.return_date)}</TableCell><TableCell>{r.supplier_name}</TableCell><TableCell className="text-muted-foreground">{r.bill_no ?? '—'}</TableCell><TableCell className="text-muted-foreground">{r.location_name}</TableCell><TableCell className="num">{amount(r.total)}</TableCell><TableCell className="text-muted-foreground">{r.notes}</TableCell></TableRow>)}</TableBody>
          </Table>
        </div>
      )}
      {creating && <NewReturnDialog onClose={() => setCreating(false)} />}
      {open && <ViewDialog row={open} onClose={() => setOpen(null)} />}
    </div>
  );
}

function ViewDialog({ row, onClose }: { row: PurchaseReturnRow; onClose: () => void }) {
  const lines = useQuery({ queryKey: ['purchase_returns', 'lines', row.id], queryFn: () => getPurchaseReturnLines(row.id ?? '') });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader><DialogTitle>Purchase return {row.return_no}</DialogTitle><DialogDescription>{dateDMY(row.return_date)} · {row.supplier_name}{row.bill_no ? ` · against ${row.bill_no}` : ''}</DialogDescription></DialogHeader>
        {lines.isLoading ? <Spinner /> : (
          <Table>
            <TableHeader><TableRow><TableHead>Item</TableHead><TableHead className="text-right">Qty</TableHead><TableHead>Unit</TableHead><TableHead className="text-right">Rate</TableHead><TableHead className="text-right">Amount</TableHead></TableRow></TableHeader>
            <TableBody>{(lines.data ?? []).map((l) => <TableRow key={l.id ?? ''}><TableCell><span className="font-medium">{l.item_code}</span> {l.item_name}</TableCell><TableCell className="num">{qty(l.qty)}</TableCell><TableCell>{l.uom_code}</TableCell><TableCell className="num">{amount(l.rate)}</TableCell><TableCell className="num">{amount(l.amount)}</TableCell></TableRow>)}</TableBody>
            <TableFooter><TableRow><TableCell colSpan={4} className="text-right">Total</TableCell><TableCell className="num">{amount(row.total)}</TableCell></TableRow></TableFooter>
          </Table>
        )}
        <DialogFooter><Button variant="outline" onClick={onClose}>Close</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function NewReturnDialog({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const [supplier, setSupplier] = useState<SupplierRow | null>(null);
  const purchases = useQuery({ queryKey: ['purchases', 'by-supplier', supplier?.id], queryFn: () => listPurchases({ search: '', page: 1, pageSize: 50, supplierId: supplier?.id ?? '' }), enabled: Boolean(supplier?.id) });
  const [purchaseId, setPurchaseId] = useState('');
  const [date, setDate] = useState(toISODate());
  const [locationId, setLocationId] = useState('');
  const [notes, setNotes] = useState('');
  const [lines, setLines] = useState<Line[]>([{ key: 1, item: null, qty: '', rate: '' }]);
  useEffect(() => { if (locations.data && !locationId) setLocationId(locations.data.find((l) => l.is_active && l.kind === 'godown')?.id ?? locations.data[0]?.id ?? ''); }, [locations.data, locationId]);
  const total = round(lines.reduce((s, l) => s + toNumber(l.qty) * toNumber(l.rate), 0), 2);
  const save = useMutation({
    mutationFn: () => {
      if (!supplier?.id) throw new Error('Choose the supplier');
      const ls = lines.filter((l) => l.item?.id && toNumber(l.qty) > 0);
      if (!ls.length) throw new Error('Add at least one line');
      return savePurchaseReturn({ supplier_id: supplier.id, purchase_id: purchaseId || null, return_date: date, location_id: locationId, notes: notes || null }, ls.map((l) => ({ item_id: l.item?.id ?? '', qty: toNumber(l.qty), rate: toNumber(l.rate) })));
    },
    onSuccess: async () => { toast({ title: 'Purchase return recorded' }); await qc.invalidateQueries({ queryKey: ['purchase_returns'] }); await qc.invalidateQueries({ queryKey: ['suppliers'] }); await qc.invalidateQueries({ queryKey: ['stock'] }); onClose(); },
    onError: (err) => toastError(err, 'Could not save'),
  });
  const update = (key: number, patch: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogHeader><DialogTitle>New purchase return</DialogTitle><DialogDescription>Quantity in the item's own unit (jars, kg…). Rate defaults to the purchase rate on Add Product.</DialogDescription></DialogHeader>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Field label="Supplier" htmlFor="pr-sup" className="col-span-2"><Combobox<SupplierRow> id="pr-sup" value={supplier} onChange={(s) => { setSupplier(s); setPurchaseId(''); }} search={searchSuppliers} queryKey="suppliers" getKey={(s) => s.id ?? ''} getLabel={(s) => s.name ?? ''} placeholder="Supplier…" autoFocus eager /></Field>
          <Field label="Against bill" htmlFor="pr-bill"><NativeSelect id="pr-bill" value={purchaseId} onChange={(e) => setPurchaseId(e.target.value)} disabled={!supplier}><option value="">— none —</option>{(purchases.data?.rows ?? []).map((p) => <option key={p.id ?? ''} value={p.id ?? ''}>{p.bill_no ?? dateDMY(p.bill_date)} · {amount(p.total)}</option>)}</NativeSelect></Field>
          <Field label="Date" htmlFor="pr-date"><Input id="pr-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
          <Field label="Goods leave from" htmlFor="pr-loc"><NativeSelect id="pr-loc" value={locationId} onChange={(e) => setLocationId(e.target.value)}>{(locations.data ?? []).filter((l) => l.is_active).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</NativeSelect></Field>
          <Field label="Notes" htmlFor="pr-notes" className="col-span-3"><Input id="pr-notes" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="damaged bags, short weight…" /></Field>
        </div>
        <Table>
          <TableHeader><TableRow><TableHead>Item</TableHead><TableHead className="w-28 text-right">Qty</TableHead><TableHead className="w-28 text-right">Rate</TableHead><TableHead className="w-28 text-right">Amount</TableHead><TableHead className="w-8" /></TableRow></TableHeader>
          <TableBody>
            {lines.map((l) => (
              <TableRow key={l.key}>
                <TableCell><Combobox<ItemRow> value={l.item} onChange={(it) => update(l.key, { item: it, rate: it ? String(toNumber(it.purchase_rate) || toNumber(it.unit_rate)) : '' })} search={(q) => searchItems(q)} queryKey="items-all" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code} — ${i.name}`} placeholder="Code or name…" aria-label="Item" />{l.item && <div className="text-xs text-muted-foreground">per {l.item.base_uom_code}</div>}</TableCell>
                <TableCell><Input type="number" step="0.001" className="num h-8" aria-label="Quantity" value={l.qty} onChange={(e) => update(l.key, { qty: e.target.value })} /></TableCell>
                <TableCell><Input type="number" step="0.01" className="num h-8" aria-label="Rate" value={l.rate} onChange={(e) => update(l.key, { rate: e.target.value })} /></TableCell>
                <TableCell className="num">{amount(toNumber(l.qty) * toNumber(l.rate))}</TableCell>
                <TableCell><Button size="sm" variant="ghost" aria-label="Remove line" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} disabled={lines.length <= 1}><Trash2 /></Button></TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter><TableRow><TableCell colSpan={3} className="text-right">Total</TableCell><TableCell className="num">{amount(total)}</TableCell><TableCell /></TableRow></TableFooter>
        </Table>
        <Button type="button" size="sm" variant="outline" onClick={() => setLines((ls) => [...ls, { key: Date.now(), item: null, qty: '', rate: '' }])}><Plus /> Line</Button>
        <DialogFooter><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={() => save.mutate()} disabled={save.isPending || !total}>{save.isPending ? 'Saving…' : 'Save return'}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
