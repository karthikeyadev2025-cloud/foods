import { useMutation, useQueryClient } from '@tanstack/react-query';
import { RefreshCw, Send, Trash2 } from 'lucide-react';
import { PageHeader } from '@/components/PageHeader';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useOnline, useOutbox } from '@/hooks/use-offline';
import { toast, toastError } from '@/hooks/use-toast';
import { dateTimeDMY } from '@/lib/format';
import { removeOutboxItem, updateOutboxItem } from '@/lib/offline';
import { replayOutbox } from '@/lib/supabase';

/** Documents saved without a connection, waiting to be sent — in the order they were made. */
export function OutboxPage() {
  const items = useOutbox();
  const online = useOnline();
  const qc = useQueryClient();
  const send = useMutation({
    mutationFn: replayOutbox,
    onSuccess: async (r) => {
      await qc.invalidateQueries();
      if (r.sent) toast({ title: `${r.sent} sent`, description: r.failed ? `${r.failed} need attention below.` : undefined });
      else if (r.failed) toast({ variant: 'destructive', title: 'Nothing could be sent', description: 'See the errors below.' });
      else if (r.stopped) toast({ variant: 'destructive', title: 'Still offline', description: 'The outbox will try again when the connection is back.' });
    },
    onError: (err) => toastError(err, 'Could not send'),
  });
  return (
    <div className="space-y-3">
      <PageHeader
        title="Outbox"
        description="Saved while offline. Sent automatically when the connection returns, in this order; an item with an error waits for you."
        actions={
          <Button size="sm" onClick={() => send.mutate()} disabled={!online || !items.length || send.isPending}>
            <Send /> {send.isPending ? 'Sending…' : 'Send now'}
          </Button>
        }
      />
      {!online && <p className="text-sm text-amber-700">Offline — nothing can be sent right now.</p>}
      {!items.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">Nothing waiting.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Document</TableHead>
                <TableHead>Made</TableHead>
                <TableHead>Attempts</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="w-32 text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {items.map((i) => (
                <TableRow key={i.id}>
                  <TableCell className="font-medium">{i.label}</TableCell>
                  <TableCell>{dateTimeDMY(i.created_at)}</TableCell>
                  <TableCell>{i.attempts}</TableCell>
                  <TableCell>{i.error ? <span className="text-destructive">{i.error}</span> : <Badge variant="outline">waiting</Badge>}</TableCell>
                  <TableCell className="text-right">
                    {i.error && (
                      <Button variant="ghost" size="icon" aria-label="Retry" onClick={() => updateOutboxItem(i.id, { error: undefined }).then(() => send.mutate())} disabled={!online || send.isPending}>
                        <RefreshCw />
                      </Button>
                    )}
                    <Button variant="ghost" size="icon" className="text-destructive" aria-label="Discard" onClick={() => removeOutboxItem(i.id)} disabled={send.isPending}>
                      <Trash2 />
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}
