import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Pencil, Plus, Trash2 } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { NavLink, useNavigate } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { searchItems, type ItemRow } from '@/features/items/api';
import { listStaff, stockLocationsApi, uomsApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, int, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import {
  batchTone,
  getRecipeIngredients,
  listBatches,
  listRecipes,
  openBatch,
  productionVariance,
  saveRecipe,
  type BatchStatus,
  type RecipeRow,
  type VarianceGroup,
} from '../api';

const TABS = [
  { key: 'batches', label: 'Batches', to: '/production' },
  { key: 'recipes', label: 'Recipes', to: '/production/recipes' },
  { key: 'variance', label: 'Variance', to: '/production/variance' },
] as const;
export type ProductionTab = (typeof TABS)[number]['key'];

export function ProductionPage({ tab = 'batches' }: { tab?: ProductionTab }) {
  const me = useMe();
  const isChief = me.data?.role === 'chief';
  return (
    <div className="space-y-3">
      <PageHeader
        title="Production"
        description={isChief ? "Today's open batch: enter what was actually used and how many boxes came out." : 'Recipe per item → open a batch with the plate count → chief enters actuals → close consumes raw material and adds finished goods.'}
      />
      {!isChief && (
        <nav className="flex gap-1 border-b" aria-label="Production sections">
          {TABS.map((t) => (
            <NavLink key={t.key} to={t.to} end className={({ isActive }) => cn('-mb-px border-b-2 px-3 py-1.5 text-sm', isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}>
              {t.label}
            </NavLink>
          ))}
        </nav>
      )}
      {tab === 'batches' && <Batches />}
      {tab === 'recipes' && !isChief && <Recipes />}
      {tab === 'variance' && !isChief && <Variance />}
    </div>
  );
}

// ------------------------------------------------------------------
function Batches() {
  const navigate = useNavigate();
  const perms = usePermissions();
  const me = useMe();
  const isChief = me.data?.role === 'chief';
  const [status, setStatus] = useState<BatchStatus | ''>('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [creating, setCreating] = useState(false);
  const batches = useQuery({ queryKey: ['production', 'batches', status, from, to], queryFn: () => listBatches({ status, from, to }) });

  const onExport = () =>
    exportToExcel('batches', (batches.data ?? []).map((b) => ({ Batch: b.batch_no, Date: dateDMY(b.production_date), Item: `${b.item_code} ${b.item_name}`, Section: b.section_name, Mestri: b.mestri_name, Chief: b.chief_name, Plates: toNumber(b.no_of_plates), 'Expected boxes': toNumber(b.expected_boxes), 'Actual boxes': toNumber(b.actual_boxes), Difference: toNumber(b.box_difference), 'Ingredient cost': toNumber(b.ingredient_cost), 'Labour cost': toNumber(b.labour_cost), 'Total cost': toNumber(b.total_cost), 'Cost / box': b.cost_per_box === null ? null : toNumber(b.cost_per_box), Status: b.status })), 'Batches');

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        {!isChief && (
          <>
            <NativeSelect aria-label="Status" className="h-8 w-36" value={status} onChange={(e) => setStatus(e.target.value as BatchStatus | '')}>
              <option value="">All statuses</option><option value="open">Open</option><option value="closed">Closed</option><option value="cancelled">Cancelled</option>
            </NativeSelect>
            <Input type="date" aria-label="From date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} />
            <Input type="date" aria-label="To date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} />
          </>
        )}
        <span className="ml-auto flex gap-2">
          <Button variant="outline" size="sm" onClick={onExport} disabled={!batches.data?.length}><Download /> Excel</Button>
          {perms.canEdit('production') && !isChief && <Button size="sm" onClick={() => setCreating(true)}><Plus /> Open batch</Button>}
        </span>
      </div>
      {batches.isLoading ? <Spinner /> : batches.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load batches: {batches.error.message}</p>
      ) : !batches.data?.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">{isChief ? 'No open batch for today.' : 'No batches yet.'}</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Batch</TableHead><TableHead>Date</TableHead><TableHead>Item</TableHead><TableHead>Mestri</TableHead><TableHead>Chief</TableHead><TableHead className="text-right">Plates</TableHead><TableHead className="text-right">Expected</TableHead><TableHead className="text-right">Actual</TableHead><TableHead className="text-right">Diff</TableHead><TableHead className="text-right">Cost / box</TableHead><TableHead>Status</TableHead></TableRow></TableHeader>
            <TableBody>
              {batches.data.map((b) => (
                <TableRow key={b.id ?? ''} className="cursor-pointer" tabIndex={0} onClick={() => navigate(`/production/batches/${b.id}`)} onKeyDown={(e) => e.key === 'Enter' && navigate(`/production/batches/${b.id}`)}>
                  <TableCell className="font-medium">{b.batch_no}</TableCell><TableCell>{dateDMY(b.production_date)}</TableCell>
                  <TableCell><span className="font-medium">{b.item_code}</span> {b.item_name}</TableCell>
                  <TableCell className="text-muted-foreground">{b.mestri_name ?? b.section_name ?? '—'}</TableCell><TableCell className="text-muted-foreground">{b.chief_name ?? '—'}</TableCell>
                  <TableCell className="num">{qty(b.no_of_plates, 0)}</TableCell><TableCell className="num">{qty(b.expected_boxes)}</TableCell>
                  <TableCell className="num">{b.status === 'open' && toNumber(b.actual_boxes) === 0 ? '—' : qty(b.actual_boxes)}</TableCell>
                  <TableCell className={cn('num', toNumber(b.box_difference) < 0 && b.status === 'closed' && 'text-destructive')}>{b.status === 'closed' ? qty(b.box_difference) : '—'}</TableCell>
                  <TableCell className="num">{b.cost_per_box === null ? '—' : amount(b.cost_per_box)}</TableCell>
                  <TableCell><Badge variant={batchTone[(b.status ?? 'open') as BatchStatus]}>{b.status}</Badge></TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {creating && <OpenBatchDialog onClose={() => setCreating(false)} />}
    </div>
  );
}

function OpenBatchDialog({ onClose }: { onClose: () => void }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const recipes = useQuery({ queryKey: ['production', 'recipes'], queryFn: listRecipes });
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const [itemId, setItemId] = useState('');
  const [plates, setPlates] = useState('');
  const [date, setDate] = useState(toISODate());
  const [chiefId, setChiefId] = useState('');
  const [locationId, setLocationId] = useState('');
  const [workers, setWorkers] = useState('');
  const [mestry, setMestry] = useState('1');
  const [labour, setLabour] = useState('');
  const active = (recipes.data ?? []).filter((r) => r.is_active);
  const recipe = active.find((r) => r.item_id === itemId);
  const expectedBoxes = recipe ? toNumber(recipe.boxes_per_plate) * toNumber(plates) : 0;

  useEffect(() => {
    if (locations.data && !locationId) {
      const l = locations.data.find((x) => x.is_active && x.kind === 'production_floor') ?? locations.data.find((x) => x.is_active && x.kind === 'godown');
      if (l) setLocationId(l.id);
    }
  }, [locations.data, locationId]);

  const open = useMutation({
    mutationFn: () => openBatch({ item_id: itemId, plates: toNumber(plates), production_date: date, location_id: locationId, chief_id: chiefId || null, no_of_workers: toNumber(workers), mestry_count: toNumber(mestry), labour_count: toNumber(labour) }),
    onSuccess: async (id) => {
      await queryClient.invalidateQueries({ queryKey: ['production'] });
      toast({ title: 'Batch opened — the sheet is ready for the chief' });
      onClose();
      navigate(`/production/batches/${id}`);
    },
    onError: (err) => toastError(err, 'Could not open the batch'),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader><DialogTitle>Open a batch</DialogTitle><DialogDescription>Pick the item and the plate count; the recipe explodes into expected usage and expected boxes.</DialogDescription></DialogHeader>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Item (with an active recipe)" htmlFor="ob-item" className="col-span-2">
            <NativeSelect id="ob-item" autoFocus value={itemId} onChange={(e) => setItemId(e.target.value)}>
              <option value="">— choose —</option>
              {active.map((r) => <option key={r.id ?? ''} value={r.item_id ?? ''}>{r.item_code} — {r.item_name}</option>)}
            </NativeSelect>
          </Field>
          <Field label="No. of plates" htmlFor="ob-plates" help={recipe ? `${qty(recipe.boxes_per_plate)} boxes per plate → ${qty(expectedBoxes)} expected boxes` : undefined}>
            <Input id="ob-plates" type="number" step="1" className="num" value={plates} onChange={(e) => setPlates(e.target.value)} />
          </Field>
          <Field label="Date" htmlFor="ob-date"><Input id="ob-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
          <Field label="Chief" htmlFor="ob-chief">
            <NativeSelect id="ob-chief" value={chiefId} onChange={(e) => setChiefId(e.target.value)}>
              <option value="">— none —</option>
              {(staff.data ?? []).filter((s) => s.is_active && s.role === 'chief').map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Stock location" htmlFor="ob-loc" help="Raw material is drawn from here; boxes go here.">
            <NativeSelect id="ob-loc" value={locationId} onChange={(e) => setLocationId(e.target.value)}>
              <option value="">— choose —</option>
              {(locations.data ?? []).filter((l) => l.is_active && l.kind !== 'vehicle').map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
            </NativeSelect>
          </Field>
          <Field label="No. of workers" htmlFor="ob-workers"><Input id="ob-workers" type="number" className="num" value={workers} onChange={(e) => setWorkers(e.target.value)} /></Field>
          <Field label="Mestry" htmlFor="ob-mestry"><Input id="ob-mestry" type="number" className="num" value={mestry} onChange={(e) => setMestry(e.target.value)} /></Field>
          <Field label="Labour" htmlFor="ob-labour"><Input id="ob-labour" type="number" className="num" value={labour} onChange={(e) => setLabour(e.target.value)} /></Field>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={() => open.mutate()} disabled={open.isPending || !itemId || toNumber(plates) <= 0}>{open.isPending ? 'Opening…' : 'Open batch'}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ------------------------------------------------------------------
function Recipes() {
  const perms = usePermissions();
  const recipes = useQuery({ queryKey: ['production', 'recipes'], queryFn: listRecipes });
  const [editing, setEditing] = useState<{ mode: 'new' } | { mode: 'edit'; row: RecipeRow } | null>(null);
  const onExport = () => exportToExcel('recipes', (recipes.data ?? []).map((r) => ({ Item: `${r.item_code} ${r.item_name}`, Section: r.section_name, Mestri: r.mestri_name, 'Pieces / plate': toNumber(r.pieces_per_plate), 'Boxes / plate': toNumber(r.boxes_per_plate), Ingredients: toNumber(r.ingredient_count), 'Cost / plate': toNumber(r.cost_per_plate), Active: r.is_active })), 'Recipes');
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-end gap-2">
        <Button variant="outline" size="sm" onClick={onExport} disabled={!recipes.data?.length}><Download /> Excel</Button>
        {perms.canEdit('production') && <Button size="sm" onClick={() => setEditing({ mode: 'new' })}><Plus /> New recipe</Button>}
      </div>
      {recipes.isLoading ? <Spinner /> : !recipes.data?.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No recipes yet. A recipe is the ingredient list per plate plus pieces per plate; the whole expected column of the production sheet rides on it.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Item</TableHead><TableHead>Section / mestri</TableHead><TableHead className="text-right">Pieces / plate</TableHead><TableHead className="text-right">Boxes / plate</TableHead><TableHead className="text-right">Ingredients</TableHead><TableHead className="text-right">Cost / plate</TableHead><TableHead>Active</TableHead>{perms.canEdit('production') && <TableHead className="w-12" />}</TableRow></TableHeader>
            <TableBody>
              {recipes.data.map((r) => (
                <TableRow key={r.id ?? ''} className={cn(!r.is_active && 'text-muted-foreground')}>
                  <TableCell><span className="font-medium">{r.item_code}</span> {r.item_name}</TableCell>
                  <TableCell className="text-muted-foreground">{r.section_name ?? '—'}{r.mestri_name ? ` · ${r.mestri_name}` : ''}</TableCell>
                  <TableCell className="num">{qty(r.pieces_per_plate, 0)}</TableCell><TableCell className="num">{qty(r.boxes_per_plate, 3)}</TableCell>
                  <TableCell className="num">{int(r.ingredient_count)}</TableCell><TableCell className="num">{amount(r.cost_per_plate)}</TableCell>
                  <TableCell>{r.is_active ? 'Yes' : 'retired'}</TableCell>
                  {perms.canEdit('production') && <TableCell><Button variant="ghost" size="icon" aria-label={`Edit recipe ${r.item_code}`} onClick={() => setEditing({ mode: 'edit', row: r })}><Pencil /></Button></TableCell>}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {editing && <RecipeDialog key={editing.mode === 'edit' ? editing.row.id : 'new'} recipe={editing.mode === 'edit' ? editing.row : undefined} onClose={() => setEditing(null)} />}
    </div>
  );
}

interface IngLine { key: string; ingredient_id: string; code: string; name: string; qty: string; uom_id: string }
let seq = 0;

function RecipeDialog({ recipe, onClose }: { recipe?: RecipeRow; onClose: () => void }) {
  const queryClient = useQueryClient();
  const uoms = useQuery({ queryKey: ['setup', 'uoms'], queryFn: uomsApi.list });
  const existing = useQuery({ queryKey: ['production', 'recipe-ingredients', recipe?.id], queryFn: () => getRecipeIngredients(recipe?.id ?? ''), enabled: Boolean(recipe?.id) });
  const [item, setItem] = useState<ItemRow | null>(null);
  const [pieces, setPieces] = useState(recipe ? String(toNumber(recipe.pieces_per_plate)) : '');
  const [active, setActive] = useState(recipe?.is_active ?? true);
  const [lines, setLines] = useState<IngLine[]>([]);
  const [entry, setEntry] = useState<ItemRow | null>(null);
  const [entryQty, setEntryQty] = useState('');
  const [entryUom, setEntryUom] = useState('');

  useEffect(() => {
    if (existing.data && lines.length === 0) {
      setLines(existing.data.map((i) => ({ key: `i${++seq}`, ingredient_id: i.ingredient_id ?? '', code: i.item_code ?? '', name: i.ingredient_name ?? '', qty: String(toNumber(i.qty_per_plate)), uom_id: i.uom_id ?? '' })));
    }
  }, [existing.data, lines.length]);

  const itemId = recipe?.item_id ?? item?.id ?? '';
  const upb = recipe?.units_per_box ?? item?.units_per_box ?? 0;
  const ppu = recipe?.pieces_per_unit ?? item?.pieces_per_unit ?? 0;
  const boxesPerPlate = upb && ppu ? toNumber(pieces) / (upb * ppu) : 0;
  const uomCode = (id: string) => uoms.data?.find((u) => u.id === id)?.code ?? '';

  const addEntry = () => {
    if (!entry?.id || toNumber(entryQty) <= 0) return;
    setLines((p) => [...p, { key: `i${++seq}`, ingredient_id: entry.id ?? '', code: entry.item_code ?? '', name: entry.name ?? '', qty: entryQty, uom_id: entryUom || entry.base_uom_id || '' }]);
    setEntry(null); setEntryQty(''); setEntryUom('');
  };

  const save = useMutation({
    mutationFn: () => {
      if (!itemId) throw new Error('Choose the item this recipe makes');
      if (toNumber(pieces) <= 0) throw new Error('Pieces per plate is required');
      if (lines.length === 0) throw new Error('Add at least one ingredient');
      return saveRecipe({ id: recipe?.id ?? undefined, item_id: itemId, pieces_per_plate: toNumber(pieces), is_active: active }, lines.map((l) => ({ ingredient_id: l.ingredient_id, qty_per_plate: toNumber(l.qty), uom_id: l.uom_id || null })));
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['production'] });
      toast({ title: 'Recipe saved' });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not save the recipe'),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogHeader><DialogTitle>{recipe ? `Recipe — ${recipe.item_code} ${recipe.item_name}` : 'New recipe'}</DialogTitle></DialogHeader>
        <div className="grid grid-cols-3 gap-3">
          {!recipe && (
            <Field label="Finished good" htmlFor="rc-item" className="col-span-3">
              <Combobox<ItemRow> id="rc-item" value={item} onChange={setItem} search={(q) => searchItems(q, { finishedOnly: true })} queryKey="items" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code} — ${i.name}`} renderOption={(i) => <span><span className="font-medium">{i.item_code}</span> {i.name}<span className="text-muted-foreground"> · {i.units_per_box}/box · {i.pieces_per_unit} pcs</span></span>} placeholder="Code or name…" autoFocus eager />
            </Field>
          )}
          <Field label="Pieces per plate" htmlFor="rc-pieces" help={upb && ppu ? `1 box = ${upb} × ${ppu} = ${upb * ppu} pieces → ${qty(boxesPerPlate, 3)} boxes per plate` : 'From the item: pieces per unit × units per box'}>
            <Input id="rc-pieces" type="number" className="num" value={pieces} onChange={(e) => setPieces(e.target.value)} />
          </Field>
          <label className="col-span-2 flex items-center gap-2 pt-6 text-sm"><input type="checkbox" className="accent-primary" checked={active} onChange={(e) => setActive(e.target.checked)} /> Active (used when opening batches)</label>
        </div>
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead className="w-40">Ingredient</TableHead><TableHead>Name</TableHead><TableHead className="w-28 text-right">Qty / plate</TableHead><TableHead className="w-24">Unit</TableHead><TableHead className="w-10" /></TableRow></TableHeader>
            <TableBody>
              {lines.map((l) => (
                <TableRow key={l.key}>
                  <TableCell className="font-medium">{l.code}</TableCell><TableCell>{l.name}</TableCell>
                  <TableCell><Input type="number" step="0.0001" className="num h-8" aria-label={`Qty ${l.code}`} value={l.qty} onChange={(e) => setLines((p) => p.map((x) => x.key === l.key ? { ...x, qty: e.target.value } : x))} /></TableCell>
                  <TableCell>{uomCode(l.uom_id)}</TableCell>
                  <TableCell><Button type="button" variant="ghost" size="icon" aria-label={`Remove ${l.code}`} onClick={() => setLines((p) => p.filter((x) => x.key !== l.key))}><Trash2 className="text-destructive" /></Button></TableCell>
                </TableRow>
              ))}
              <TableRow className="bg-muted/30">
                <TableCell colSpan={2}>
                  <Combobox<ItemRow> value={entry} onChange={(i) => { setEntry(i); setEntryUom(i?.base_uom_id ?? ''); }} search={(q) => searchItems(q)} queryKey="items-all" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code} — ${i.name}`} renderOption={(i) => <span><span className="font-medium">{i.item_code}</span> {i.name}<span className="text-muted-foreground"> · {i.type?.replace('_', ' ')}</span></span>} placeholder="Raw material code or name…" aria-label="Ingredient" />
                </TableCell>
                <TableCell><Input type="number" step="0.0001" className="num h-8" aria-label="Quantity per plate" value={entryQty} onChange={(e) => setEntryQty(e.target.value)} disabled={!entry} onKeyDown={(e) => e.key === 'Enter' && (e.preventDefault(), addEntry())} /></TableCell>
                <TableCell>
                  <NativeSelect aria-label="Unit" className="h-8" value={entryUom} onChange={(e) => setEntryUom(e.target.value)} disabled={!entry}>
                    {(uoms.data ?? []).filter((u) => u.is_active).map((u) => <option key={u.id} value={u.id}>{u.code}</option>)}
                  </NativeSelect>
                </TableCell>
                <TableCell><Button type="button" size="sm" variant="secondary" onClick={addEntry} disabled={!entry}>Add</Button></TableCell>
              </TableRow>
            </TableBody>
          </Table>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={() => save.mutate()} disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save recipe'}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ------------------------------------------------------------------
function Variance() {
  const me = useMe();
  const today = toISODate();
  const monthStart = today.slice(0, 8) + '01';
  const [from, setFrom] = useState(monthStart);
  const [to, setTo] = useState(today);
  const [group, setGroup] = useState<VarianceGroup>('item');
  const orgId = me.data?.org_id ?? '';
  const rows = useQuery({ queryKey: ['production', 'variance', orgId, from, to, group], queryFn: () => productionVariance(orgId, from, to, group), enabled: Boolean(orgId) });
  const totals = useMemo(() => {
    const d = rows.data ?? [];
    const s = (k: keyof (typeof d)[number]) => d.reduce((a, r) => a + toNumber(r[k] as number | string | null), 0);
    return { expected: s('expected_boxes'), actual: s('actual_boxes'), expCost: s('expected_ingredient_cost'), actCost: s('actual_ingredient_cost'), labour: s('labour_cost'), total: s('total_cost') };
  }, [rows.data]);

  const onExport = () => exportToExcel(`variance-${group}`, (rows.data ?? []).map((r) => ({ Group: r.group_label, Batches: toNumber(r.batches), Plates: toNumber(r.plates), 'Expected boxes': toNumber(r.expected_boxes), 'Actual boxes': toNumber(r.actual_boxes), 'Box variance': toNumber(r.box_variance), 'Variance %': r.box_variance_pct === null ? null : toNumber(r.box_variance_pct), 'Expected ingredient cost': toNumber(r.expected_ingredient_cost), 'Actual ingredient cost': toNumber(r.actual_ingredient_cost), 'Ingredient variance': toNumber(r.ingredient_variance), 'Labour cost': toNumber(r.labour_cost), 'Total cost': toNumber(r.total_cost), 'Cost / box': r.cost_per_box === null ? null : toNumber(r.cost_per_box) })), 'Variance');

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-end gap-2">
        <Field label="From" htmlFor="va-from"><Input id="va-from" type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label="To" htmlFor="va-to"><Input id="va-to" type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
        <Field label="By" htmlFor="va-group">
          <NativeSelect id="va-group" className="h-8 w-36" value={group} onChange={(e) => setGroup(e.target.value as VarianceGroup)}>
            <option value="item">Item</option><option value="mestri">Mestri</option><option value="week">Week</option>
          </NativeSelect>
        </Field>
        <Button variant="outline" size="sm" className="ml-auto" onClick={onExport} disabled={!rows.data?.length}><Download /> Excel</Button>
      </div>
      <p className="text-xs text-muted-foreground">Closed batches only. Box variance = actual − expected; ingredient variance = (actual − expected usage) × purchase rate. This is what catches leakage.</p>
      {rows.isLoading ? <Spinner /> : !rows.data?.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No closed batches in this range.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>{group === 'item' ? 'Item' : group === 'mestri' ? 'Mestri' : 'Week'}</TableHead><TableHead className="text-right">Batches</TableHead><TableHead className="text-right">Plates</TableHead><TableHead className="text-right">Expected</TableHead><TableHead className="text-right">Actual</TableHead><TableHead className="text-right">Boxes ±</TableHead><TableHead className="text-right">%</TableHead><TableHead className="text-right">Ingr. expected</TableHead><TableHead className="text-right">Ingr. actual</TableHead><TableHead className="text-right">Ingr. ±</TableHead><TableHead className="text-right">Labour</TableHead><TableHead className="text-right">Cost / box</TableHead></TableRow></TableHeader>
            <TableBody>
              {rows.data.map((r) => (
                <TableRow key={r.group_key ?? ''}>
                  <TableCell className="font-medium">{r.group_label}</TableCell>
                  <TableCell className="num">{int(r.batches)}</TableCell><TableCell className="num">{qty(r.plates, 0)}</TableCell>
                  <TableCell className="num">{qty(r.expected_boxes)}</TableCell><TableCell className="num">{qty(r.actual_boxes)}</TableCell>
                  <TableCell className={cn('num font-medium', toNumber(r.box_variance) < 0 && 'text-destructive')}>{qty(r.box_variance)}</TableCell>
                  <TableCell className={cn('num', toNumber(r.box_variance_pct) < 0 && 'text-destructive')}>{r.box_variance_pct === null ? '—' : `${qty(r.box_variance_pct)}%`}</TableCell>
                  <TableCell className="num">{amount(r.expected_ingredient_cost)}</TableCell><TableCell className="num">{amount(r.actual_ingredient_cost)}</TableCell>
                  <TableCell className={cn('num font-medium', toNumber(r.ingredient_variance) > 0 && 'text-destructive')}>{amount(r.ingredient_variance)}</TableCell>
                  <TableCell className="num">{amount(r.labour_cost)}</TableCell><TableCell className="num">{r.cost_per_box === null ? '—' : amount(r.cost_per_box)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell colSpan={3} className="text-right">Total</TableCell>
                <TableCell className="num">{qty(totals.expected)}</TableCell><TableCell className="num">{qty(totals.actual)}</TableCell>
                <TableCell className={cn('num', totals.actual - totals.expected < 0 && 'text-destructive')}>{qty(totals.actual - totals.expected)}</TableCell><TableCell />
                <TableCell className="num">{amount(totals.expCost)}</TableCell><TableCell className="num">{amount(totals.actCost)}</TableCell>
                <TableCell className={cn('num', totals.actCost - totals.expCost > 0 && 'text-destructive')}>{amount(totals.actCost - totals.expCost)}</TableCell>
                <TableCell className="num">{amount(totals.labour)}</TableCell><TableCell className="num">{totals.actual > 0 ? amount(totals.total / totals.actual) : '—'}</TableCell>
              </TableRow>
            </TableFooter>
          </Table>
        </div>
      )}
    </div>
  );
}
