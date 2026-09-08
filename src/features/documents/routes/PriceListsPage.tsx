import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Pencil, Plus, Trash2, Users, Wand2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import { useForm } from 'react-hook-form';
import { NavLink, useParams } from 'react-router-dom';
import { z } from 'zod';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { searchItems, type ItemRow } from '@/features/items/api';
import { routesApi, sectionsApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, int, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { assignPriceList, bulkUpdatePriceList, discountSchemesApi, listDiscountSchemes, listPriceLists, priceListRates, priceListsApi, setPriceListRate, type BulkMode, type DiscountSchemeRow, type PriceListRow } from '../api';

const TABS = [{ key: 'lists', label: 'Price lists' }, { key: 'schemes', label: 'Discount schemes' }] as const;

export function PriceListsPage({ tab = 'lists' }: { tab?: 'lists' | 'schemes' }) {
  const { tab: param } = useParams();
  const current = param === 'schemes' ? 'schemes' : tab;
  return (
    <div className="space-y-3">
      <PageHeader title="Pricing" description="Named price lists per customer with effective dates, and schemes for quantity discounts. Rate at billing: customer override → price group → the customer's list → the default list → the item master." />
      <nav className="flex gap-1 border-b" aria-label="Pricing">{TABS.map((t) => <NavLink key={t.key} to={t.key === 'lists' ? '/pricing' : '/pricing/schemes'} end className={({ isActive }) => cn('-mb-px border-b-2 px-3 py-1.5 text-sm', isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}>{t.label}</NavLink>)}</nav>
      {current === 'lists' ? <ListsPanel /> : <SchemesPanel />}
    </div>
  );
}

// ------------------------------------------------------------------ lists
const listSchema = z.object({ name: z.string().trim().min(1, 'Name is required').max(80), valid_from: z.string(), valid_to: z.string(), is_default: z.boolean(), is_active: z.boolean(), notes: z.string().trim().max(200) });
type ListForm = z.infer<typeof listSchema>;

function ListsPanel() {
  const qc = useQueryClient();
  const perms = usePermissions();
  const canEdit = perms.canEdit('items');
  const lists = useQuery({ queryKey: ['pricing', 'lists'], queryFn: listPriceLists });
  const [selected, setSelected] = useState('');
  const [editing, setEditing] = useState<{ row: PriceListRow | null } | null>(null);
  const [bulk, setBulk] = useState(false);
  const [assigning, setAssigning] = useState(false);
  const rows = lists.data ?? [];
  const current = rows.find((l) => l.id === selected) ?? rows[0] ?? null;
  const remove = useMutation({
    mutationFn: (id: string) => priceListsApi.remove(id),
    onSuccess: async () => { toast({ title: 'Price list removed' }); await qc.invalidateQueries({ queryKey: ['pricing'] }); },
    onError: (e) => toastError(e, 'Could not remove (customers may still be on it)'),
  });
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        {rows.map((l) => (
          <button key={l.id ?? ''} type="button" onClick={() => setSelected(l.id ?? '')} className={cn('rounded-md border px-3 py-1.5 text-left text-sm hover:border-primary/60', current?.id === l.id && 'border-primary bg-primary/5', !l.is_active && 'opacity-60')}>
            <span className="font-medium">{l.name}</span>{l.is_default && <Badge className="ml-2">default</Badge>}{l.is_expired && <Badge variant="destructive" className="ml-2">expired</Badge>}
            <div className="text-xs text-muted-foreground">{int(l.item_count)} rates · {int(l.customer_count)} customers{l.valid_to ? ` · till ${dateDMY(l.valid_to)}` : ''}</div>
          </button>
        ))}
        {canEdit && <Button size="sm" variant="outline" onClick={() => setEditing({ row: null })}><Plus /> Price list</Button>}
      </div>
      {lists.isLoading ? <Spinner /> : !current ? <p className="text-sm text-muted-foreground">No price lists yet. Without one, every customer pays the item master rate.</p> : (
        <>
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="text-base font-semibold">{current.name}</h3>
            {canEdit && <Button size="sm" variant="ghost" aria-label="Edit list" onClick={() => setEditing({ row: current })}><Pencil /></Button>}
            <span className="ml-auto flex gap-2">
              {canEdit && <Button size="sm" variant="outline" onClick={() => setAssigning(true)}><Users /> Assign customers</Button>}
              {canEdit && <Button size="sm" variant="outline" onClick={() => setBulk(true)}><Wand2 /> Bulk update</Button>}
              {perms.canDelete('items') && !current.is_default && <Button size="sm" variant="ghost" className="text-destructive" onClick={() => remove.mutate(current.id ?? '')}><Trash2 /> Remove</Button>}
            </span>
          </div>
          <RatesGrid list={current} canEdit={canEdit} />
        </>
      )}
      {editing && <ListDialog row={editing.row} onClose={() => setEditing(null)} />}
      {bulk && current && <BulkDialog list={current} lists={rows} onClose={() => setBulk(false)} />}
      {assigning && current && <AssignDialog list={current} onClose={() => setAssigning(false)} />}
    </div>
  );
}

function RatesGrid({ list, canEdit }: { list: PriceListRow; canEdit: boolean }) {
  const qc = useQueryClient();
  const rates = useQuery({ queryKey: ['pricing', 'rates', list.id], queryFn: () => priceListRates(list.id ?? '') });
  const [filter, setFilter] = useState('');
  const [onlySet, setOnlySet] = useState(false);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const set = useMutation({
    mutationFn: ({ itemId, rate }: { itemId: string; rate: number | null }) => setPriceListRate(list.id ?? '', itemId, rate),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['pricing'] }),
    onError: (e) => toastError(e, 'Could not save the rate'),
  });
  const rows = useMemo(() => (rates.data ?? []).filter((r) => (!onlySet || r.list_rate !== null) && (!filter || `${r.item_code} ${r.item_name} ${r.section_name ?? ''}`.toLowerCase().includes(filter.toLowerCase()))), [rates.data, filter, onlySet]);
  const commit = (itemId: string) => {
    const raw = drafts[itemId];
    if (raw === undefined) return;
    const current = rates.data?.find((r) => r.item_id === itemId)?.list_rate ?? null;
    const next = raw.trim() === '' ? null : toNumber(raw);
    setDrafts((d) => { const { [itemId]: _drop, ...rest } = d; void _drop; return rest; });
    if (next === current) return;
    set.mutate({ itemId, rate: next });
  };
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Code, name, section…" aria-label="Filter items" className="h-8 w-60" value={filter} onChange={(e) => setFilter(e.target.value)} />
        <label className="flex items-center gap-1 text-sm"><Checkbox checked={onlySet} onChange={(e) => setOnlySet(e.target.checked)} /> Only items with a rate on this list</label>
        <Button size="sm" variant="outline" className="ml-auto" onClick={() => exportToExcel(`price-list-${list.name}`, rows.map((r) => ({ Code: r.item_code, Item: r.item_name, Section: r.section_name, 'Units/box': r.units_per_box, 'Master rate': toNumber(r.master_rate), 'List rate': r.list_rate === null ? '' : toNumber(r.list_rate), 'Box rate': r.list_box_rate === null ? '' : toNumber(r.list_box_rate) })), list.name ?? 'Rates')} disabled={!rows.length}><Download /> Excel</Button>
      </div>
      {rates.isLoading ? <Spinner /> : (
        <div className="max-h-[60vh] overflow-auto rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Code</TableHead><TableHead>Item</TableHead><TableHead>Section</TableHead><TableHead className="text-right">Units/box</TableHead><TableHead className="text-right">Master rate</TableHead><TableHead className="w-32 text-right">List rate</TableHead><TableHead className="text-right">Box rate</TableHead></TableRow></TableHeader>
            <TableBody>
              {rows.map((r) => (
                <TableRow key={r.item_id} className={cn(r.list_rate === null && 'text-muted-foreground')}>
                  <TableCell className="font-medium">{r.item_code}</TableCell><TableCell>{r.item_name}</TableCell><TableCell className="text-xs">{r.section_name}</TableCell>
                  <TableCell className="num">{int(r.units_per_box)}</TableCell><TableCell className="num">{amount(r.master_rate)}</TableCell>
                  <TableCell>{canEdit ? <Input type="number" step="0.01" className="num h-8" aria-label={`Rate for ${r.item_code}`} placeholder="—" value={drafts[r.item_id] ?? (r.list_rate === null ? '' : String(toNumber(r.list_rate)))} onChange={(e) => setDrafts((d) => ({ ...d, [r.item_id]: e.target.value }))} onBlur={() => commit(r.item_id)} onKeyDown={(e) => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); }} /> : <span className="num">{r.list_rate === null ? '—' : amount(r.list_rate)}</span>}</TableCell>
                  <TableCell className="num">{r.list_box_rate === null ? '' : amount(r.list_box_rate)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      <p className="text-xs text-muted-foreground">Blank = not on this list; the customer falls through to the default list, then the master. Enter or Tab saves.</p>
    </div>
  );
}

function ListDialog({ row, onClose }: { row: PriceListRow | null; onClose: () => void }) {
  const qc = useQueryClient();
  const form = useForm<ListForm>({ resolver: zodResolver(listSchema), defaultValues: row ? { name: row.name ?? '', valid_from: row.valid_from ?? '', valid_to: row.valid_to ?? '', is_default: row.is_default ?? false, is_active: row.is_active ?? true, notes: row.notes ?? '' } : { name: '', valid_from: toISODate(), valid_to: '', is_default: false, is_active: true, notes: '' } });
  const save = useMutation({
    mutationFn: (v: ListForm) => { const values = { name: v.name, valid_from: v.valid_from || null, valid_to: v.valid_to || null, is_default: v.is_default, is_active: v.is_active, notes: v.notes || null }; return row?.id ? priceListsApi.update(row.id, values) : priceListsApi.create(values); },
    onSuccess: async () => { toast({ title: 'Price list saved' }); await qc.invalidateQueries({ queryKey: ['pricing'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not save'),
  });
  const e = form.formState.errors;
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>{row ? 'Edit price list' : 'New price list'}</DialogTitle></DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3">
          <Field label="Name" htmlFor="pl-name" className="col-span-2" error={e.name?.message}><Input id="pl-name" autoFocus placeholder="Wholesale / Guntur route / Diwali 2026" {...form.register('name')} /></Field>
          <Field label="Valid from" htmlFor="pl-from"><Input id="pl-from" type="date" {...form.register('valid_from')} /></Field>
          <Field label="Valid to" htmlFor="pl-to" help="Blank = no end."><Input id="pl-to" type="date" {...form.register('valid_to')} /></Field>
          <Field label="Notes" htmlFor="pl-notes" className="col-span-2"><Input id="pl-notes" {...form.register('notes')} /></Field>
          <label className="flex items-center gap-2 text-sm"><Checkbox {...form.register('is_default')} /> Default for customers without a list</label>
          <label className="flex items-center gap-2 text-sm"><Checkbox {...form.register('is_active')} /> Active</label>
          <DialogFooter className="col-span-2 pt-2"><Button type="button" variant="outline" onClick={onClose}>Cancel</Button><Button type="submit" disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save'}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function BulkDialog({ list, lists, onClose }: { list: PriceListRow; lists: PriceListRow[]; onClose: () => void }) {
  const qc = useQueryClient();
  const sections = useQuery({ queryKey: ['setup', 'sections'], queryFn: sectionsApi.list });
  const [mode, setMode] = useState<BulkMode>('pct');
  const [value, setValue] = useState('0');
  const [sectionId, setSectionId] = useState('');
  const [sourceId, setSourceId] = useState('');
  const run = useMutation({
    mutationFn: () => bulkUpdatePriceList(list.id ?? '', mode, toNumber(value), sectionId, sourceId),
    onSuccess: async (n) => { toast({ title: `${n} rate${n === 1 ? '' : 's'} updated` }); await qc.invalidateQueries({ queryKey: ['pricing'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not update'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogHeader><DialogTitle>Bulk update — {list.name}</DialogTitle><DialogDescription>Changes are applied at once and can be re-run; there is no undo, so export first if unsure.</DialogDescription></DialogHeader>
        <Field label="What" htmlFor="bk-mode"><NativeSelect id="bk-mode" value={mode} onChange={(e) => setMode(e.target.value as BulkMode)}><option value="pct">Change existing rates by %</option><option value="add">Change existing rates by ₹</option><option value="copy_master">Fill from the item master (± %)</option><option value="copy_list">Copy another list (± %)</option></NativeSelect></Field>
        <Field label={mode === 'add' ? 'Amount (₹, negative to reduce)' : 'Percent (negative to reduce)'} htmlFor="bk-val"><Input id="bk-val" type="number" step="0.01" className="num" value={value} onChange={(e) => setValue(e.target.value)} /></Field>
        {mode === 'copy_list' && <Field label="Copy from" htmlFor="bk-src"><NativeSelect id="bk-src" value={sourceId} onChange={(e) => setSourceId(e.target.value)}><option value="">— pick —</option>{lists.filter((l) => l.id !== list.id).map((l) => <option key={l.id ?? ''} value={l.id ?? ''}>{l.name}</option>)}</NativeSelect></Field>}
        <Field label="Only this section" htmlFor="bk-sec"><NativeSelect id="bk-sec" value={sectionId} onChange={(e) => setSectionId(e.target.value)}><option value="">All sections</option>{(sections.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.code ? `${s.code} ` : ''}{s.name}</option>)}</NativeSelect></Field>
        <DialogFooter><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={() => run.mutate()} disabled={run.isPending || (mode === 'copy_list' && !sourceId)}>{run.isPending ? 'Updating…' : 'Apply'}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function AssignDialog({ list, onClose }: { list: PriceListRow; onClose: () => void }) {
  const qc = useQueryClient();
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list });
  const [routeId, setRouteId] = useState('');
  const [town, setTown] = useState('');
  const run = useMutation({
    mutationFn: () => assignPriceList(list.id ?? '', routeId, town),
    onSuccess: async (n) => { toast({ title: `${n} customer${n === 1 ? '' : 's'} moved to ${list.name}` }); await qc.invalidateQueries({ queryKey: ['pricing'] }); await qc.invalidateQueries({ queryKey: ['customers'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not assign'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogHeader><DialogTitle>Put customers on {list.name}</DialogTitle><DialogDescription>Single customers are set on their own form. This moves everyone matching the filter; leave both blank for all active customers.</DialogDescription></DialogHeader>
        <Field label="Route" htmlFor="as-route"><NativeSelect id="as-route" value={routeId} onChange={(e) => setRouteId(e.target.value)}><option value="">Any route</option>{(routes.data ?? []).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</NativeSelect></Field>
        <Field label="Town" htmlFor="as-town"><Input id="as-town" value={town} onChange={(e) => setTown(e.target.value)} placeholder="any" /></Field>
        <DialogFooter><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={() => run.mutate()} disabled={run.isPending}>{run.isPending ? 'Assigning…' : 'Assign'}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ------------------------------------------------------------------ schemes
const schemeSchema = z.object({ name: z.string().trim().min(1, 'Name is required').max(80), scope: z.enum(['item', 'section', 'all']), item_id: z.string(), section_id: z.string(), min_boxes: z.coerce.number().positive('Minimum boxes must be above zero'), discount_pct: z.coerce.number().min(0).max(100), free_boxes: z.coerce.number().min(0), valid_from: z.string(), valid_to: z.string(), is_active: z.boolean() })
  .refine((v) => v.discount_pct > 0 || v.free_boxes > 0, { path: ['discount_pct'], message: 'Give a discount % or free boxes' })
  .refine((v) => v.scope !== 'item' || v.item_id, { path: ['item_id'], message: 'Pick the item' })
  .refine((v) => v.scope !== 'section' || v.section_id, { path: ['section_id'], message: 'Pick the section' });
type SchemeForm = z.infer<typeof schemeSchema>;

function SchemesPanel() {
  const qc = useQueryClient();
  const perms = usePermissions();
  const canEdit = perms.canEdit('items');
  const schemes = useQuery({ queryKey: ['pricing', 'schemes'], queryFn: listDiscountSchemes });
  const [editing, setEditing] = useState<{ row: DiscountSchemeRow | null } | null>(null);
  const remove = useMutation({
    mutationFn: (id: string) => discountSchemesApi.remove(id),
    onSuccess: async () => { toast({ title: 'Scheme removed' }); await qc.invalidateQueries({ queryKey: ['pricing', 'schemes'] }); },
    onError: (e) => toastError(e, 'Could not remove'),
  });
  const rows = schemes.data ?? [];
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <p className="max-w-2xl text-sm text-muted-foreground">Minimum boxes on a bill line → a discount % or free boxes. An item scheme beats a section scheme beats an all-items one. Press "Apply schemes" on a draft invoice to use them.</p>
        {canEdit && <Button size="sm" className="ml-auto" onClick={() => setEditing({ row: null })}><Plus /> New scheme</Button>}
      </div>
      {schemes.isLoading ? <Spinner /> : !rows.length ? <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No schemes.</p> : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Name</TableHead><TableHead>Applies to</TableHead><TableHead className="text-right">Min boxes</TableHead><TableHead className="text-right">Discount</TableHead><TableHead className="text-right">Free boxes</TableHead><TableHead>Valid</TableHead><TableHead>Active</TableHead><TableHead /></TableRow></TableHeader>
            <TableBody>
              {rows.map((s) => (
                <TableRow key={s.id ?? ''} className={cn(s.is_expired && 'text-muted-foreground')}>
                  <TableCell className="font-medium">{s.name}</TableCell>
                  <TableCell>{s.item_code ? `${s.item_code} — ${s.item_name}` : s.section_name ? `Section ${s.section_name}` : 'All items'}</TableCell>
                  <TableCell className="num">{qty(s.min_boxes)}</TableCell><TableCell className="num">{toNumber(s.discount_pct) ? `${qty(s.discount_pct, 1)}%` : ''}</TableCell><TableCell className="num">{toNumber(s.free_boxes) ? qty(s.free_boxes) : ''}</TableCell>
                  <TableCell className="text-xs">{s.valid_from ? dateDMY(s.valid_from) : ''}{s.valid_to ? ` → ${dateDMY(s.valid_to)}` : ''}{s.is_expired && <Badge variant="destructive" className="ml-1">expired</Badge>}</TableCell>
                  <TableCell>{s.is_active ? 'Yes' : 'No'}</TableCell>
                  <TableCell className="whitespace-nowrap text-right">{canEdit && <Button size="sm" variant="ghost" aria-label="Edit" onClick={() => setEditing({ row: s })}><Pencil /></Button>}{perms.canDelete('items') && <Button size="sm" variant="ghost" aria-label="Delete" onClick={() => remove.mutate(s.id ?? '')}><Trash2 /></Button>}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {editing && <SchemeDialog row={editing.row} onClose={() => setEditing(null)} />}
    </div>
  );
}

function SchemeDialog({ row, onClose }: { row: DiscountSchemeRow | null; onClose: () => void }) {
  const qc = useQueryClient();
  const sections = useQuery({ queryKey: ['setup', 'sections'], queryFn: sectionsApi.list });
  const [item, setItem] = useState<ItemRow | null>(row?.item_id ? ({ id: row.item_id, item_code: row.item_code, name: row.item_name } as ItemRow) : null);
  const form = useForm<SchemeForm>({ resolver: zodResolver(schemeSchema), defaultValues: row ? { name: row.name ?? '', scope: row.item_id ? 'item' : row.section_id ? 'section' : 'all', item_id: row.item_id ?? '', section_id: row.section_id ?? '', min_boxes: toNumber(row.min_boxes), discount_pct: toNumber(row.discount_pct), free_boxes: toNumber(row.free_boxes), valid_from: row.valid_from ?? '', valid_to: row.valid_to ?? '', is_active: row.is_active ?? true } : { name: '', scope: 'item', item_id: '', section_id: '', min_boxes: 10, discount_pct: 0, free_boxes: 0, valid_from: toISODate(), valid_to: '', is_active: true } });
  const scope = form.watch('scope');
  const save = useMutation({
    mutationFn: (v: SchemeForm) => { const values = { name: v.name, item_id: v.scope === 'item' ? v.item_id : null, section_id: v.scope === 'section' ? v.section_id : null, min_boxes: v.min_boxes, discount_pct: v.discount_pct, free_boxes: v.free_boxes, valid_from: v.valid_from || null, valid_to: v.valid_to || null, is_active: v.is_active }; return row?.id ? discountSchemesApi.update(row.id, values) : discountSchemesApi.create(values); },
    onSuccess: async () => { toast({ title: 'Scheme saved' }); await qc.invalidateQueries({ queryKey: ['pricing', 'schemes'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not save'),
  });
  const e = form.formState.errors;
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>{row ? 'Edit scheme' : 'New discount scheme'}</DialogTitle></DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3">
          <Field label="Name" htmlFor="sc-name" className="col-span-2" error={e.name?.message}><Input id="sc-name" autoFocus placeholder="1 free on 10 — laddu" {...form.register('name')} /></Field>
          <Field label="Applies to" htmlFor="sc-scope"><NativeSelect id="sc-scope" {...form.register('scope')}><option value="item">One item</option><option value="section">A section</option><option value="all">All items</option></NativeSelect></Field>
          {scope === 'item' && <Field label="Item" htmlFor="sc-item" error={e.item_id?.message}><Combobox<ItemRow> id="sc-item" value={item} onChange={(i) => { setItem(i); form.setValue('item_id', i?.id ?? '', { shouldValidate: true }); }} search={(q) => searchItems(q, { finishedOnly: true })} queryKey="items-finished" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code} — ${i.name}`} placeholder="Code or name…" eager /></Field>}
          {scope === 'section' && <Field label="Section" htmlFor="sc-sec" error={e.section_id?.message}><NativeSelect id="sc-sec" {...form.register('section_id')}><option value="">— pick —</option>{(sections.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.code ? `${s.code} ` : ''}{s.name}</option>)}</NativeSelect></Field>}
          {scope === 'all' && <div />}
          <Field label="Minimum boxes" htmlFor="sc-min" error={e.min_boxes?.message}><Input id="sc-min" type="number" step="0.001" className="num" {...form.register('min_boxes')} /></Field>
          <Field label="Discount %" htmlFor="sc-pct" error={e.discount_pct?.message}><Input id="sc-pct" type="number" step="0.01" className="num" {...form.register('discount_pct')} /></Field>
          <Field label="Free boxes per minimum" htmlFor="sc-free" error={e.free_boxes?.message}><Input id="sc-free" type="number" step="0.001" className="num" {...form.register('free_boxes')} /></Field>
          <Field label="Valid from" htmlFor="sc-from"><Input id="sc-from" type="date" {...form.register('valid_from')} /></Field>
          <Field label="Valid to" htmlFor="sc-to"><Input id="sc-to" type="date" {...form.register('valid_to')} /></Field>
          <label className="col-span-2 flex items-center gap-2 text-sm"><Checkbox {...form.register('is_active')} /> Active</label>
          <DialogFooter className="col-span-2 pt-2"><Button type="button" variant="outline" onClick={onClose}>Cancel</Button><Button type="submit" disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save'}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
