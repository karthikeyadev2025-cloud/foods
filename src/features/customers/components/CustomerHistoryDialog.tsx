import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { amount, dateDMY, qty, whole } from '@/lib/format';
import { cn } from '@/lib/utils';
import { customerLastRates, customerRecentBills, historyKeys, pastBillLines } from '../history-api';

/**
 * What this customer was charged before, while a new bill is being written.
 *
 * The counter asks one question — "what did we give him last time?" — and until
 * now the only place that answer lived was in somebody's head. A regular can be
 * on 40 while the price list says 42, and the argument happens with the
 * customer standing there.
 *
 * Rates first, because that is the question. The bills are underneath for when
 * it is really "what was on that bill".
 */
export function CustomerHistoryDialog({
  customerId,
  customerName,
  onClose,
  onUseRate,
}: {
  customerId: string;
  customerName: string;
  onClose: () => void;
  /** Puts a rate straight onto the bill being written, so nobody re-types it. */
  onUseRate?: (itemId: string, rate: number) => void;
}) {
  const [tab, setTab] = useState<'rates' | 'bills'>('rates');
  const [openBill, setOpenBill] = useState<string | null>(null);

  const rates = useQuery({
    queryKey: historyKeys.rates(customerId),
    queryFn: () => customerLastRates(customerId),
  });
  const bills = useQuery({
    queryKey: historyKeys.bills(customerId),
    queryFn: () => customerRecentBills(customerId),
    enabled: tab === 'bills',
  });
  const lines = useQuery({
    queryKey: historyKeys.lines(openBill ?? ''),
    queryFn: () => pastBillLines(openBill ?? ''),
    enabled: Boolean(openBill),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle>{customerName}</DialogTitle>
          <DialogDescription>What this customer has been charged before. Nothing here changes the bill unless you press Use.</DialogDescription>
        </DialogHeader>

        <div className="flex gap-1 border-b" role="tablist">
          {([['rates', 'Last rates'], ['bills', 'Past bills']] as const).map(([key, label]) => (
            <button
              key={key}
              type="button"
              role="tab"
              aria-selected={tab === key}
              onClick={() => setTab(key)}
              className={cn(
                '-mb-px border-b-2 px-3 py-1.5 text-sm',
                tab === key ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground',
              )}
            >
              {label}
            </button>
          ))}
        </div>

        {tab === 'rates' ? (
          rates.isLoading ? <Spinner /> : rates.error ? (
            <p role="alert" className="text-sm text-destructive">{rates.error.message}</p>
          ) : !rates.data?.length ? (
            <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
              Nothing billed to this customer yet — the rate on a new line comes from the price list.
            </p>
          ) : (
            <div className="max-h-[26rem] overflow-auto rounded-md border">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Code</TableHead>
                    <TableHead>Product</TableHead>
                    <TableHead className="text-right">Last rate</TableHead>
                    <TableHead className="text-right">Boxes</TableHead>
                    <TableHead>When</TableHead>
                    <TableHead className="text-right">Times</TableHead>
                    {onUseRate && <TableHead className="w-16" />}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rates.data.map((r) => (
                    <TableRow key={r.item_id}>
                      <TableCell className="font-medium">{r.item_code}</TableCell>
                      <TableCell>{r.item_name}</TableCell>
                      <TableCell className="num font-semibold">{amount(r.rate)}</TableCell>
                      <TableCell className="num text-muted-foreground">{qty(r.boxes)}</TableCell>
                      <TableCell className="text-muted-foreground">
                        {dateDMY(r.invoice_date)}
                        <span className="ml-1 text-xs">· {r.invoice_no}</span>
                      </TableCell>
                      <TableCell className="num text-muted-foreground">{whole(r.times_billed)}</TableCell>
                      {onUseRate && (
                        <TableCell className="text-right">
                          <Button size="sm" variant="outline" onClick={() => onUseRate(r.item_id, Number(r.rate))}>
                            Use
                          </Button>
                        </TableCell>
                      )}
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )
        ) : bills.isLoading ? <Spinner /> : bills.error ? (
          <p role="alert" className="text-sm text-destructive">{bills.error.message}</p>
        ) : !bills.data?.length ? (
          <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No bills yet.</p>
        ) : (
          <div className="max-h-[26rem] space-y-2 overflow-auto">
            {bills.data.map((b) => (
              <div key={b.id} className="rounded-md border">
                <button
                  type="button"
                  className="flex w-full items-center gap-3 px-3 py-2 text-left text-sm hover:bg-muted/50"
                  onClick={() => setOpenBill((cur) => (cur === b.id ? null : b.id))}
                  aria-expanded={openBill === b.id}
                >
                  <span className="font-medium">{b.invoice_no}</span>
                  <span className="text-muted-foreground">{dateDMY(b.invoice_date)}</span>
                  {b.status === 'cancelled' && <Badge variant="destructive">cancelled</Badge>}
                  <span className="ml-auto text-muted-foreground">{whole(b.lines)} lines · {qty(b.boxes)} boxes</span>
                  <span className="num w-24 text-right font-medium">{amount(b.total)}</span>
                </button>
                {openBill === b.id && (
                  lines.isLoading ? <div className="p-3"><Spinner /></div> : (
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead>Code</TableHead><TableHead>Product</TableHead>
                          <TableHead className="text-right">Boxes</TableHead>
                          <TableHead className="text-right">Rate</TableHead>
                          <TableHead className="text-right">Amount</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {(lines.data ?? []).map((l, i) => (
                          <TableRow key={`${l.item_code}-${i}`}>
                            <TableCell className="font-medium">{l.item_code}</TableCell>
                            <TableCell>{l.item_name}</TableCell>
                            <TableCell className="num">{qty(l.boxes)}</TableCell>
                            <TableCell className="num font-medium">{amount(l.rate)}</TableCell>
                            <TableCell className="num">{amount(l.amount)}</TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  )
                )}
              </div>
            ))}
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
