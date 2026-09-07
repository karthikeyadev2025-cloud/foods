import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, int, qty, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { batchTone, cancelBatch, closeBatch, getBatch, getBatchIngredients, updateBatchActuals, type BatchStatus } from '../api';

/**
 * The production sheet, headed by the item name, in the client's column order:
 * Ingredients · Quantity · No of Plates · Total Usage per Plate · Total Used by Chief ·
 * Difference · No of Workers · Mestry · Labour — plus Expected vs Actual Boxes.
 */
export function BatchPage() {
  const { id } = useParams();
  const me = useMe();
  const perms = usePermissions();
  const queryClient = useQueryClient();
  const batch = useQuery({ queryKey: ['production', 'batch', id], queryFn: () => getBatch(id ?? ''), enabled: Boolean(id) });
  const lines = useQuery({ queryKey: ['production', 'batch-lines', id], queryFn: () => getBatchIngredients(id ?? ''), enabled: Boolean(id) });
  const [used, setUsed] = useState<Record<string, string>>({});
  const [actualBoxes, setActualBoxes] = useState('');
  const [workers, setWorkers] = useState('');
  const [mestry, setMestry] = useState('');
  const [labour, setLabour] = useState('');
  const [labourCost, setLabourCost] = useState('');
  const [notes, setNotes] = useState('');
  const [closeOpen, setCloseOpen] = useState(false);

  useEffect(() => {
    if (batch.data) {
      setActualBoxes(toNumber(batch.data.actual_boxes) ? String(toNumber(batch.data.actual_boxes)) : '');
      setWorkers(String(toNumber(batch.data.no_of_workers)));
      setMestry(String(toNumber(batch.data.mestry_count)));
      setLabour(String(toNumber(batch.data.labour_count)));
      setLabourCost(toNumber(batch.data.labour_cost) ? String(toNumber(batch.data.labour_cost)) : '');
      setNotes(batch.data.notes ?? '');
    }
  }, [batch.data]);
  useEffect(() => {
    if (lines.data) setUsed(Object.fromEntries(lines.data.map((l) => [l.id ?? '', toNumber(l.total_used_by_chief) ? String(toNumber(l.total_used_by_chief)) : ''])));
  }, [lines.data]);

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: ['production'] });
    await queryClient.invalidateQueries({ queryKey: ['stock'] });
    await queryClient.invalidateQueries({ queryKey: ['items'] });
  };
  const save = useMutation({
    mutationFn: () =>
      updateBatchActuals(id ?? '', {
        actual_boxes: toNumber(actualBoxes),
        no_of_workers: toNumber(workers),
        mestry_count: toNumber(mestry),
        labour_count: toNumber(labour),
        labour_cost: toNumber(labourCost),
        notes: notes || null,
        lines: (lines.data ?? []).map((l) => ({ id: l.id ?? '', actual_qty: toNumber(used[l.id ?? '']) })),
      }),
    onSuccess: async () => {
      await invalidate();
      toast({ title: 'Actuals saved' });
    },
    onError: (err) => toastError(err, 'Could not save actuals'),
  });
  const close = useMutation({
    mutationFn: async () => {
      await save.mutateAsync();
      await closeBatch(id ?? '');
    },
    onSuccess: async () => {
      await invalidate();
      setCloseOpen(false);
      toast({ title: 'Batch closed — raw material consumed, boxes added to stock' });
    },
    onError: (err) => toastError(err, 'Could not close the batch'),
  });
  const cancel = useMutation({
    mutationFn: () => cancelBatch(id ?? ''),
    onSuccess: async () => {
      await invalidate();
      toast({ title: 'Batch cancelled' });
    },
    onError: (err) => toastError(err, 'Could not cancel the batch'),
  });

  if (batch.isLoading || lines.isLoading) return <Spinner label="Loading batch…" />;
  if (!batch.data || !lines.data) return <p role="alert" className="text-sm text-destructive">Batch not found, or not visible to your role.</p>;
  const b = batch.data;
  const st = (b.status ?? 'open') as BatchStatus;
  const isChief = me.data?.role === 'chief';
  const canEnter = perms.canEdit('production') && st === 'open';
  const canClose = canEnter && !isChief;
  const expected = toNumber(b.expected_boxes);
  const actual = st === 'open' ? toNumber(actualBoxes) : toNumber(b.actual_boxes);
  const diff = actual - expected;
  const usedOf = (lId: string, fallback: unknown) => (st === 'open' ? toNumber(used[lId]) : toNumber(fallback as number | string | null));

  const onExport = () =>
    exportToExcel(`batch-${b.batch_no}`, lines.data.map((l) => ({ Ingredients: l.ingredient, Quantity: toNumber(l.quantity), 'No of Plates': toNumber(l.no_of_plates), 'Total Usage per Plate': toNumber(l.total_usage_per_plate), 'Total Used by Chief': usedOf(l.id ?? '', l.total_used_by_chief), Difference: usedOf(l.id ?? '', l.total_used_by_chief) - toNumber(l.total_usage_per_plate), 'No of Workers': toNumber(workers), Mestry: toNumber(mestry), Labour: toNumber(labour), Unit: l.uom_code, Rate: toNumber(l.rate) })), b.item_name ?? 'Sheet');

  return (
    <div className="space-y-4">
      <PageHeader
        title={`${b.item_name}`}
        description={`Batch ${b.batch_no} · ${dateDMY(b.production_date)} · ${b.mestri_name ? `Mestri ${b.mestri_name}` : b.section_name ?? ''}${b.chief_name ? ` · Chief ${b.chief_name}` : ''} · ${b.location_name ?? ''}`}
        actions={
          <>
            <Badge variant={batchTone[st]}>{st}</Badge>
            <Button variant="outline" size="sm" onClick={onExport}><Download /> Excel</Button>
            {canClose && <Button size="sm" variant="ghost" className="text-destructive" onClick={() => cancel.mutate()} disabled={cancel.isPending}>Cancel batch</Button>}
            {!isChief && <Button asChild variant="ghost" size="sm"><Link to="/production">← Batches</Link></Button>}
          </>
        }
      />

      <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
        <Tile label="No. of plates" value={qty(b.no_of_plates, 0)} />
        <Tile label="Expected boxes" value={qty(expected)} sub={`${qty(b.expected_jars)} jars · ${qty(b.expected_pieces, 0)} pieces`} />
        <Tile label="Actual boxes" value={actual ? qty(actual) : '—'} sub={actual ? `${qty(actual * toNumber(b.units_per_box))} jars` : 'not entered yet'} />
        <Tile label="Variance" value={actual ? qty(diff) : '—'} tone={actual && diff < 0 ? 'bad' : actual && diff >= 0 ? 'good' : undefined} sub={actual && expected ? `${qty((diff * 100) / expected)}%` : undefined} />
      </div>

      <div className="rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Ingredients</TableHead>
              <TableHead className="text-right">Quantity</TableHead>
              <TableHead className="text-right">No of Plates</TableHead>
              <TableHead className="text-right">Total Usage per Plate</TableHead>
              <TableHead className="w-36 text-right">Total Used by Chief</TableHead>
              <TableHead className="text-right">Difference</TableHead>
              <TableHead className="text-right">No of Workers</TableHead>
              <TableHead className="text-right">Mestry</TableHead>
              <TableHead className="text-right">Labour</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {lines.data.map((l, i) => {
              const lid = l.id ?? '';
              const u = usedOf(lid, l.total_used_by_chief);
              const d = u - toNumber(l.total_usage_per_plate);
              return (
                <TableRow key={lid}>
                  <TableCell className="font-medium">{l.ingredient} <span className="text-xs text-muted-foreground">({l.uom_code})</span></TableCell>
                  <TableCell className="num">{qty(l.quantity, 3)}</TableCell>
                  <TableCell className="num">{qty(l.no_of_plates, 0)}</TableCell>
                  <TableCell className="num">{qty(l.total_usage_per_plate, 3)}</TableCell>
                  <TableCell className="num">
                    {canEnter ? <Input type="number" step="0.001" className="num h-8" aria-label={`Used ${l.ingredient}`} value={used[lid] ?? ''} onChange={(e) => setUsed((p) => ({ ...p, [lid]: e.target.value }))} /> : qty(l.total_used_by_chief, 3)}
                  </TableCell>
                  <TableCell className={cn('num font-medium', d > 0 && 'text-destructive', d < 0 && 'text-green-700')}>{u || st !== 'open' ? qty(d, 3) : '—'}</TableCell>
                  <TableCell className="num text-muted-foreground">{i === 0 ? (canEnter ? <Input type="number" className="num h-8" aria-label="No of workers" value={workers} onChange={(e) => setWorkers(e.target.value)} /> : int(b.no_of_workers)) : ''}</TableCell>
                  <TableCell className="num text-muted-foreground">{i === 0 ? (canEnter ? <Input type="number" className="num h-8" aria-label="Mestry" value={mestry} onChange={(e) => setMestry(e.target.value)} /> : int(b.mestry_count)) : ''}</TableCell>
                  <TableCell className="num text-muted-foreground">{i === 0 ? (canEnter ? <Input type="number" className="num h-8" aria-label="Labour" value={labour} onChange={(e) => setLabour(e.target.value)} /> : int(b.labour_count)) : ''}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell colSpan={3} className="text-right font-semibold">Expected vs Actual Boxes</TableCell>
              <TableCell className="num font-semibold">{qty(expected)}</TableCell>
              <TableCell className="num">{canEnter ? <Input type="number" step="0.001" className="num h-8 font-semibold" aria-label="Actual boxes" value={actualBoxes} onChange={(e) => setActualBoxes(e.target.value)} /> : qty(b.actual_boxes)}</TableCell>
              <TableCell className={cn('num font-semibold', actual && diff < 0 && 'text-destructive')}>{actual ? qty(diff) : '—'}</TableCell>
              <TableCell colSpan={3} />
            </TableRow>
          </TableFooter>
        </Table>
      </div>

      <Card>
        <CardContent className="grid grid-cols-2 gap-3 pt-4 md:grid-cols-4">
          <Field label="Labour cost (₹)" htmlFor="bt-labour-cost" help="Counted into the batch cost.">
            <Input id="bt-labour-cost" type="number" step="0.01" className="num" value={labourCost} onChange={(e) => setLabourCost(e.target.value)} disabled={!canEnter} />
          </Field>
          <Field label="Notes" htmlFor="bt-notes" className="col-span-2 md:col-span-3">
            <Input id="bt-notes" value={notes} onChange={(e) => setNotes(e.target.value)} disabled={!canEnter} />
          </Field>
          {st === 'closed' && (
            <>
              <Tile label="Ingredient cost" value={amount(b.ingredient_cost)} />
              <Tile label="Labour cost" value={amount(b.labour_cost)} />
              <Tile label="Total cost" value={amount(b.total_cost)} />
              <Tile label="Cost per box" value={b.cost_per_box === null ? '—' : amount(b.cost_per_box)} />
            </>
          )}
        </CardContent>
      </Card>

      {canEnter && (
        <div className="flex flex-wrap justify-end gap-2">
          <Button variant="secondary" onClick={() => save.mutate()} disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save actuals'}</Button>
          {canClose && <Button onClick={() => setCloseOpen(true)} disabled={toNumber(actualBoxes) <= 0}>Close batch</Button>}
          {isChief && <p className="self-center text-xs text-muted-foreground">The production head closes the batch after checking your figures.</p>}
        </div>
      )}

      <Dialog open={closeOpen} onOpenChange={setCloseOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Close batch {b.batch_no}?</DialogTitle>
            <DialogDescription>Raw material is consumed at the chief&apos;s actual figures, {qty(toNumber(actualBoxes))} boxes of {b.item_name} go into {b.location_name}, and the batch is costed. This cannot be reopened.</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCloseOpen(false)}>Not yet</Button>
            <Button onClick={() => close.mutate()} disabled={close.isPending}>{close.isPending ? 'Closing…' : 'Close batch'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function Tile({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: 'good' | 'bad' }) {
  return (
    <div className={cn('rounded-md border bg-card p-2', tone === 'good' && 'border-green-300 bg-green-50', tone === 'bad' && 'border-red-300 bg-red-50')}>
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="text-lg font-semibold tabular-nums">{value}</div>
      {sub && <div className="text-xs text-muted-foreground">{sub}</div>}
    </div>
  );
}
