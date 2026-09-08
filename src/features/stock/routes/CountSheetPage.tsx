import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Check, Download, Printer } from 'lucide-react';
import { Fragment, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, dateTimeDMY, qty, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { getCount, getCountLines, postStockCount, updateStockCount, type CountLineRow } from '../inventory-api';

/** T9.4 — the count sheet: print blank, type counted boxes (saved as you go), post the variance. */
export function CountSheetPage() {
  const { id = '' } = useParams();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const me = useMe();
  const perms = usePermissions();
  const count = useQuery({ queryKey: ['stock', 'count', id], queryFn: () => getCount(id) });
  const lines = useQuery({ queryKey: ['stock', 'count-lines', id], queryFn: () => getCountLines(id) });
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [onlyDiff, setOnlyDiff] = useState(false);
  const [blank, setBlank] = useState(false);
  useEffect(() => { document.title = count.data ? `Count ${count.data.count_no}` : 'Stock count'; }, [count.data]);
  const editable = perms.canEdit('stock') && count.data?.status === 'open';

  const save = useMutation({
    mutationFn: (l: { item_id: string; counted_boxes: number | null }[]) => updateStockCount(id, l),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['stock', 'count'] }),
    onError: (e) => toastError(e, 'Could not save the count'),
  });
  const post = useMutation({
    mutationFn: () => postStockCount(id),
    onSuccess: async (n) => { toast({ title: `${n} adjustment${n === 1 ? '' : 's'} posted` }); await qc.invalidateQueries({ queryKey: ['stock'] }); },
    onError: (e) => toastError(e, 'Could not post'),
  });
  const commit = (l: CountLineRow) => {
    const raw = drafts[l.item_id ?? ''];
    if (raw === undefined) return;
    setDrafts((d) => { const { [l.item_id ?? '']: _x, ...rest } = d; void _x; return rest; });
    const next = raw.trim() === '' ? null : toNumber(raw);
    if (next === (l.counted_boxes === null ? null : toNumber(l.counted_boxes))) return;
    save.mutate([{ item_id: l.item_id ?? '', counted_boxes: next }]);
  };

  const groups = useMemo(() => {
    const rows = (lines.data ?? []).filter((l) => !onlyDiff || (l.counted_boxes !== null && toNumber(l.variance_boxes) !== 0));
    const map = new Map<string, { name: string; rows: CountLineRow[] }>();
    for (const r of rows) { const k = r.section_name ?? 'OTHERS'; if (!map.has(k)) map.set(k, { name: k, rows: [] }); map.get(k)?.rows.push(r); }
    return [...map.values()];
  }, [lines.data, onlyDiff]);

  if (count.isLoading || lines.isLoading) return <Spinner />;
  if (!count.data) return <p role="alert" className="text-sm text-destructive">Count not found.</p>;
  const c = count.data;
  const all = lines.data ?? [];
  const counted = all.filter((l) => l.counted_boxes !== null);
  const varianceValue = counted.reduce((s, l) => s + toNumber(l.variance_value), 0);

  return (
    <div className="space-y-3">
      <PageHeader
        title={`Stock count ${c.count_no}`}
        description={<span className="flex flex-wrap items-center gap-2">{dateDMY(c.count_date)} · {c.location_name}{c.section_name ? ` · ${c.section_name}` : ''} <Badge variant={c.status === 'open' ? 'default' : c.status === 'posted' ? 'secondary' : 'destructive'}>{c.status}</Badge>{c.status === 'posted' && <span className="text-xs">posted by {c.posted_by_name} {dateTimeDMY(c.posted_at)}</span>}</span>}
        actions={<>
          <label className="no-print flex items-center gap-1 text-sm"><Checkbox checked={blank} onChange={(e) => setBlank(e.target.checked)} /> Blank sheet</label>
          <Button variant="outline" size="sm" onClick={() => window.print()}><Printer /> Print</Button>
          <Button variant="outline" size="sm" onClick={() => exportToExcel(`count-${c.count_no}`, all.map((l) => ({ Section: l.section_name, Code: l.item_code, Item: l.item_name, Pack: l.pack_code, 'System (boxes)': toNumber(l.system_boxes), 'Counted (boxes)': l.counted_boxes === null ? '' : toNumber(l.counted_boxes), 'Difference (boxes)': l.counted_boxes === null ? '' : toNumber(l.variance_boxes), 'Value': l.counted_boxes === null ? '' : toNumber(l.variance_value) })), 'Count')}><Download /> Excel</Button>
          {editable && <Button size="sm" onClick={() => post.mutate()} disabled={post.isPending || !counted.length}><Check /> Post {counted.length ? `${counted.filter((l) => toNumber(l.variance_boxes) !== 0).length} difference${counted.filter((l) => toNumber(l.variance_boxes) !== 0).length === 1 ? '' : 's'}` : ''}</Button>}
          <Button asChild variant="ghost" size="sm"><Link to="/stock/counts">← Counts</Link></Button>
        </>}
      />
      <div className="hidden print:block"><h2 className="text-lg font-semibold">{me.data?.org_name}</h2><p className="text-sm">Stock count {c.count_no} · {dateDMY(c.count_date)} · {c.location_name}{c.section_name ? ` · ${c.section_name}` : ''}{blank ? ' · counted by: ________________' : ''}</p></div>
      <div className="no-print flex flex-wrap items-center gap-2 text-sm">
        <label className="flex items-center gap-1"><Checkbox checked={onlyDiff} onChange={(e) => setOnlyDiff(e.target.checked)} /> Only differences</label>
        <span className="text-muted-foreground">{counted.length} of {all.length} counted{counted.length ? ` · difference value ${amount(varianceValue)}` : ''}</span>
        {editable && <span className="text-xs text-muted-foreground">Enter or Tab saves each line. Leave a line blank to skip it.</span>}
      </div>
      <div className="rounded-md border">
        <Table>
          <TableHeader><TableRow><TableHead className="w-24">Code</TableHead><TableHead>Item</TableHead><TableHead className="w-16">Pack</TableHead><TableHead className="w-24 text-right">System</TableHead><TableHead className="w-32 text-right">Counted</TableHead><TableHead className="w-24 text-right">Difference</TableHead><TableHead className="w-28 text-right">Value</TableHead></TableRow></TableHeader>
          <TableBody>
            {groups.map((g) => (
              <Fragment key={g.name}>
                <TableRow className="bg-muted/50 hover:bg-muted/50"><TableCell colSpan={7} className="font-semibold">{g.name}</TableCell></TableRow>
                {g.rows.map((l) => {
                  const diff = l.counted_boxes === null ? null : toNumber(l.variance_boxes);
                  return (
                    <TableRow key={l.id ?? ''} className={cn(diff !== null && diff !== 0 && 'bg-amber-50/60')}>
                      <TableCell className="font-medium">{l.item_code}</TableCell><TableCell>{l.item_name}</TableCell><TableCell className="text-muted-foreground">{l.pack_code}</TableCell>
                      <TableCell className="num">{blank ? '' : qty(l.system_boxes)}</TableCell>
                      <TableCell className="num">{blank ? <span className="inline-block h-5 w-24 border-b border-black print:inline-block" /> : editable ? <Input type="number" step="0.001" min={0} className="num h-8" aria-label={`Counted boxes for ${l.item_code}`} placeholder="—" value={drafts[l.item_id ?? ''] ?? (l.counted_boxes === null ? '' : String(toNumber(l.counted_boxes)))} onChange={(e) => setDrafts((d) => ({ ...d, [l.item_id ?? '']: e.target.value }))} onBlur={() => commit(l)} onKeyDown={(e) => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); }} /> : l.counted_boxes === null ? <span className="text-muted-foreground">—</span> : qty(l.counted_boxes)}</TableCell>
                      <TableCell className={cn('num font-medium', diff !== null && diff < 0 && 'text-destructive', diff !== null && diff > 0 && 'text-green-700')}>{blank || diff === null ? '' : diff > 0 ? `+${qty(diff)}` : qty(diff)}</TableCell>
                      <TableCell className="num text-muted-foreground">{blank || diff === null ? '' : amount(l.variance_value)}</TableCell>
                    </TableRow>
                  );
                })}
              </Fragment>
            ))}
          </TableBody>
          {!blank && <TableFooter><TableRow><TableCell colSpan={5} className="text-right">Difference value ({counted.length} counted)</TableCell><TableCell className="num">{qty(counted.reduce((s, l) => s + toNumber(l.variance_boxes), 0))}</TableCell><TableCell className="num">{amount(varianceValue)}</TableCell></TableRow></TableFooter>}
        </Table>
      </div>
      {c.status === 'posted' && <p className="text-xs text-muted-foreground">Posted differences are adjustment rows in the ledger (Stock → Movements shows them against this count). <button type="button" className="text-primary hover:underline" onClick={() => navigate('/stock/movements')}>Open movements</button></p>}
    </div>
  );
}
