import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { AlertTriangle, Copy, Download, PackageX } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { dateDMY, int, qty, toNumber } from '@/lib/format';
import {
  duplicateStockRows,
  itemProblems,
  negativeStock,
  removeDuplicateStockRows,
} from '../api';

/**
 * What is wrong with the data, in one place.
 *
 * The system being right and the data being wrong is the harder half, because
 * nothing breaks — the shop keeps billing, and every figure derived from the
 * bad rows is quietly wrong until somebody happens to look. This is the
 * looking, done once and read in a minute.
 */
export function DataHealth() {
  const perms = usePermissions();
  const negatives = useQuery({ queryKey: ['stock', 'negative'], queryFn: negativeStock });
  const problems = useQuery({ queryKey: ['stock', 'item-problems'], queryFn: itemProblems });
  const dupes = useQuery({ queryKey: ['stock', 'duplicates'], queryFn: duplicateStockRows });

  if (negatives.isLoading || problems.isLoading || dupes.isLoading) return <Spinner />;

  const neg = negatives.data ?? [];
  const probs = problems.data ?? [];
  const dup = dupes.data ?? [];
  const clean = !neg.length && !probs.length && !dup.length;

  return (
    <div className="space-y-8">
      {clean && (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
          Nothing to fix. No product is showing less than nothing, every active product can be billed, and no
          movement is recorded twice.
        </p>
      )}

      <NegativeStock rows={neg} />
      <ItemProblems rows={probs} />
      <Duplicates rows={dup} canFix={perms.canEdit('stock')} />
    </div>
  );
}

function Section({ icon, title, count, lead, children, action }: {
  icon: React.ReactNode;
  title: string;
  count: number;
  lead: string;
  children: React.ReactNode;
  action?: React.ReactNode;
}) {
  if (!count) return null;
  return (
    <section className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        {icon}
        <h3 className="text-sm font-semibold">
          {title} <span className="text-muted-foreground">({count})</span>
        </h3>
        <span className="ml-auto flex items-center gap-2">{action}</span>
      </div>
      <p className="max-w-3xl text-sm text-muted-foreground">{lead}</p>
      <div className="overflow-x-auto rounded-md border">{children}</div>
    </section>
  );
}

function NegativeStock({ rows }: { rows: Awaited<ReturnType<typeof negativeStock>> }) {
  return (
    <Section
      icon={<PackageX className="h-4 w-4 text-destructive" aria-hidden />}
      title="Showing less than nothing"
      count={rows.length}
      lead="More has gone out than ever came in. Usually a purchase or a production batch that was never entered for goods
            that were then billed. Every profit and stock figure for these products is wrong until it is traced — and the
            honest way to close the gap is a stock count, which posts an adjustment somebody has signed for."
      action={
        <Button
          variant="outline"
          size="sm"
          onClick={() =>
            exportToExcel(
              'negative-stock',
              rows.map((r) => ({
                Code: r.item_code,
                Product: r.name,
                Section: r.section_name,
                Godown: r.location_name,
                Boxes: toNumber(r.boxes),
                'Came in': toNumber(r.came_in),
                'Went out': toNumber(r.went_out),
                Movements: toNumber(r.movements),
                'Last moved': r.last_moved ? dateDMY(r.last_moved) : '',
              })),
              'Negative stock',
            )
          }
        >
          <Download /> Excel
        </Button>
      }
    >
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Code</TableHead>
            <TableHead>Product</TableHead>
            <TableHead>Godown</TableHead>
            <TableHead className="text-right">Short by</TableHead>
            <TableHead className="text-right">Came in</TableHead>
            <TableHead className="text-right">Went out</TableHead>
            <TableHead>Last moved</TableHead>
            <TableHead />
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((r) => (
            <TableRow key={`${r.item_id}-${r.location_id}`}>
              <TableCell className="font-medium">{r.item_code}</TableCell>
              <TableCell>
                {r.name}
                {r.section_name && <div className="text-xs text-muted-foreground">{r.section_name}</div>}
              </TableCell>
              <TableCell className="text-muted-foreground">{r.location_name ?? '—'}</TableCell>
              <TableCell className="num font-medium text-destructive">{qty(r.boxes)} boxes</TableCell>
              <TableCell className="num text-muted-foreground">{qty(r.came_in)}</TableCell>
              <TableCell className="num text-muted-foreground">{qty(r.went_out)}</TableCell>
              <TableCell className="text-muted-foreground">{r.last_moved ? dateDMY(r.last_moved) : '—'}</TableCell>
              <TableCell>
                {/* Straight to the movements for this one product: the row that
                    explains the hole is nearly always the newest one there. */}
                <Button asChild variant="ghost" size="sm">
                  <Link to={`/stock/movements?item=${r.item_id}`}>See movements</Link>
                </Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </Section>
  );
}

function ItemProblems({ rows }: { rows: Awaited<ReturnType<typeof itemProblems>> }) {
  return (
    <Section
      icon={<AlertTriangle className="h-4 w-4 text-amber-600" aria-hidden />}
      title="Products the master cannot really use"
      count={rows.length}
      lead="One line per fault, so a product with three things wrong appears three times and every one of them gets
            fixed rather than only the first. Click the code to open the product."
      action={
        <Button
          variant="outline"
          size="sm"
          onClick={() =>
            exportToExcel(
              'item-problems',
              rows.map((r) => ({ Code: r.item_code, Product: r.name, Problem: r.problem, 'What to do': r.fix })),
              'Item problems',
            )
          }
        >
          <Download /> Excel
        </Button>
      }
    >
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Code</TableHead>
            <TableHead>Product</TableHead>
            <TableHead>Problem</TableHead>
            <TableHead>What to do</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((r, i) => (
            <TableRow key={`${r.item_id}-${r.problem}-${i}`}>
              <TableCell className="font-medium">
                <Link className="underline-offset-2 hover:underline" to={`/items/${r.item_id}`}>
                  {r.item_code}
                </Link>
              </TableCell>
              <TableCell>{r.name}</TableCell>
              <TableCell className="whitespace-nowrap">{r.problem}</TableCell>
              <TableCell className="text-muted-foreground">{r.fix}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </Section>
  );
}

function Duplicates({ rows, canFix }: { rows: Awaited<ReturnType<typeof duplicateStockRows>>; canFix: boolean }) {
  const [confirm, setConfirm] = useState(false);
  const queryClient = useQueryClient();

  // The count comes from the same dry run the button offers to apply, so the
  // number on screen is the number that will be deleted — not an estimate.
  const extras = useQuery({ queryKey: ['stock', 'duplicates', 'count'], queryFn: () => removeDuplicateStockRows(false) });

  const clear = useMutation({
    mutationFn: () => removeDuplicateStockRows(true),
    onSuccess: async (n) => {
      await queryClient.invalidateQueries({ queryKey: ['stock'] });
      setConfirm(false);
      toast({ title: `${n} duplicate ${n === 1 ? 'row' : 'rows'} removed`, description: 'One of each set was kept.' });
    },
    onError: (err) => toastError(err, 'Could not clear the duplicates'),
  });

  return (
    <Section
      icon={<Copy className="h-4 w-4 text-amber-600" aria-hidden />}
      title="The same movement recorded twice"
      count={rows.length}
      lead="Identical rows — same product, godown, kind, date, quantity and source. An import run twice is the usual
            cause, and every copy is counted in stock as if the goods really arrived again."
      action={
        canFix && (extras.data ?? 0) > 0 ? (
          <Button variant="outline" size="sm" onClick={() => setConfirm(true)}>
            Remove {int(extras.data)} extra {extras.data === 1 ? 'row' : 'rows'}
          </Button>
        ) : null
      }
    >
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Code</TableHead>
            <TableHead>Product</TableHead>
            <TableHead>Godown</TableHead>
            <TableHead>Kind</TableHead>
            <TableHead>Date</TableHead>
            <TableHead className="text-right">Each</TableHead>
            <TableHead className="text-right">Copies</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((r, i) => (
            <TableRow key={`${r.item_id}-${r.txn_date}-${i}`}>
              <TableCell className="font-medium">{r.item_code}</TableCell>
              <TableCell>{r.name}</TableCell>
              <TableCell className="text-muted-foreground">{r.location_name ?? '—'}</TableCell>
              <TableCell className="text-muted-foreground">{r.txn_type}</TableCell>
              <TableCell>{r.txn_date ? dateDMY(r.txn_date) : '—'}</TableCell>
              <TableCell className="num">{qty(r.qty_base)}</TableCell>
              <TableCell className="num font-medium">{int(r.copies)}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>

      <Dialog open={confirm} onOpenChange={setConfirm}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Remove {int(extras.data)} duplicate stock {extras.data === 1 ? 'row' : 'rows'}?</DialogTitle>
            <DialogDescription>
              One row of each set is kept — the earliest — and the extra copies are deleted. Stock figures for those
              products will change, which is the point: they are currently counting goods that only arrived once.
              This cannot be undone, so take a backup first if you are unsure.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirm(false)}>
              Keep them
            </Button>
            <Button variant="destructive" onClick={() => clear.mutate()} disabled={clear.isPending}>
              Remove the extras
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Section>
  );
}
