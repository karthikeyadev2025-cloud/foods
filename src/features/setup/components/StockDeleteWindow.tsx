import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { useMe } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { dateDMY } from '@/lib/format';
import { getOrg, setStockDeleteWindow, stockDeleteOpen } from '../api';

/**
 * "This option is available only to enter original data — after that we will
 * intimate and then remove that option in stock."
 *
 * The removal belongs to the shop, not to a release, so it lives here. It is a
 * date rather than a tick box because a tick box stays ticked: the shop means
 * to tell us, the week gets busy, and the ledger is still open at the next
 * stock take. A date closes by itself and says on screen when.
 */
export function StockDeleteWindow() {
  const me = useMe();
  const queryClient = useQueryClient();
  const org = useQuery({ queryKey: ['setup', 'org'], queryFn: getOrg });
  const until = org.data?.stock_delete_until ?? null;
  const open = stockDeleteOpen(until);
  const isOwner = me.data?.role === 'owner';

  const set = useMutation({
    mutationFn: (days: number | null) => setStockDeleteWindow(days),
    onSuccess: async (value) => {
      await queryClient.invalidateQueries({ queryKey: ['setup', 'org'] });
      await queryClient.invalidateQueries({ queryKey: ['stock'] });
      toast({
        title: value ? `Stock corrections open until ${dateDMY(value)}` : 'Stock corrections stopped',
        description: value
          ? 'Typed and imported stock rows can be deleted until then.'
          : 'From now on a stock figure can only be changed by the document that made it.',
      });
    },
    onError: (err) => toastError(err, 'Could not change it'),
  });

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base">Correcting stock while the opening figures go in</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        <p className="text-muted-foreground">
          While this is open, a stock movement that was typed in or imported can be deleted from Stock → Movements.
          A movement that came from a bill, a purchase or a batch is never deletable here — that document has to be
          cancelled instead, and the stock goes back on its own.
        </p>

        {open ? (
          <p className="rounded-md border border-amber-300 bg-amber-50 p-3 text-amber-900">
            <span className="font-medium">Open until {dateDMY(until)}.</span> Stop it as soon as the real figures are in.
            A stock ledger that can be edited is how a day&apos;s takings go missing with nothing left to show for it.
          </p>
        ) : (
          <p className="rounded-md border bg-muted/40 p-3">
            <span className="font-medium">Closed.</span> Stock can only be changed by the documents that move it.
          </p>
        )}

        {isOwner ? (
          <div className="flex flex-wrap gap-2">
            {open && (
              <Button variant="destructive" size="sm" disabled={set.isPending} onClick={() => set.mutate(null)}>
                Stop now
              </Button>
            )}
            <Button variant="outline" size="sm" disabled={set.isPending} onClick={() => set.mutate(30)}>
              {open ? 'Extend by 30 days' : 'Open for 30 days'}
            </Button>
            <Button variant="outline" size="sm" disabled={set.isPending} onClick={() => set.mutate(7)}>
              {open ? 'Cut back to 7 days' : 'Open for 7 days'}
            </Button>
          </div>
        ) : (
          <p className="text-xs text-muted-foreground">Only an owner can open or close this.</p>
        )}
      </CardContent>
    </Card>
  );
}
