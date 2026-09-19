import { useQuery } from '@tanstack/react-query';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { amount, dateDMY, qty, whole } from '@/lib/format';
import { supplierLastRates, supplierHistoryKeys } from '../api';

/**
 * What this supplier last charged — the buying side of the bill screen's rate
 * history, asked for as "the same format and functionality".
 *
 * Buying has no cancelled bill to skip over, so every purchase line counts and
 * there is only the one list.
 */
export function SupplierHistoryDialog({
  supplierId,
  supplierName,
  onClose,
  onUseRate,
}: {
  supplierId: string;
  supplierName: string;
  onClose: () => void;
  onUseRate?: (itemId: string, rate: number) => void;
}) {
  const rates = useQuery({
    queryKey: supplierHistoryKeys.rates(supplierId),
    queryFn: () => supplierLastRates(supplierId),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle>{supplierName}</DialogTitle>
          <DialogDescription>What this supplier last charged. Nothing here changes the bill unless you press Use.</DialogDescription>
        </DialogHeader>

        {rates.isLoading ? <Spinner /> : rates.error ? (
          <p role="alert" className="text-sm text-destructive">{rates.error.message}</p>
        ) : !rates.data?.length ? (
          <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
            Nothing bought from this supplier yet — the rate on a new line comes from the product&apos;s purchase rate.
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
                      {dateDMY(r.bill_date)}
                      {r.bill_no && <span className="ml-1 text-xs">· {r.bill_no}</span>}
                    </TableCell>
                    <TableCell className="num text-muted-foreground">{whole(r.times_bought)}</TableCell>
                    {onUseRate && (
                      <TableCell className="text-right">
                        <Button type="button" size="sm" variant="outline" onClick={() => onUseRate(r.item_id, Number(r.rate))}>
                          Use
                        </Button>
                      </TableCell>
                    )}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
