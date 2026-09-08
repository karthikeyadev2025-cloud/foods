import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Phone, Plus } from 'lucide-react';
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Textarea } from '@/components/ui/textarea';
import { usePermissions } from '@/features/auth/hooks';
import { searchCustomers, type CustomerRow } from '@/features/customers/api';
import { toastError } from '@/hooks/use-toast';
import { dateTimeDMY, int } from '@/lib/format';
import { createInboundOrder, listInboundOrders, orderTone, type OrderStatus } from '../api';

export function OrdersQueue() {
  const navigate = useNavigate();
  const perms = usePermissions();
  const [status, setStatus] = useState<OrderStatus | ''>('new');
  const [logging, setLogging] = useState(false);
  const orders = useQuery({ queryKey: ['messaging', 'orders', status], queryFn: () => listInboundOrders(status), refetchInterval: 30_000 });
  const rows = orders.data ?? [];

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <NativeSelect aria-label="Status" className="h-8 w-40" value={status} onChange={(e) => setStatus(e.target.value as OrderStatus | '')}>
          <option value="new">New</option><option value="invoiced">Invoiced</option><option value="rejected">Rejected</option><option value="">All</option>
        </NativeSelect>
        <p className="text-sm text-muted-foreground">WhatsApp and call orders land here. Open one, check the lines, convert. Nothing becomes a bill on its own.</p>
        {perms.canEdit('messaging') && <Button size="sm" className="ml-auto" onClick={() => setLogging(true)}><Phone /> Log a phone order</Button>}
      </div>
      {orders.isLoading ? <Spinner /> : orders.error ? (
        <p role="alert" className="text-sm text-destructive">{orders.error.message}</p>
      ) : !rows.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">{status === 'new' ? 'No new orders waiting.' : 'Nothing here.'}</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Received</TableHead><TableHead>From</TableHead><TableHead>Via</TableHead><TableHead>Message</TableHead><TableHead className="text-right">Lines</TableHead><TableHead>Status</TableHead></TableRow></TableHeader>
            <TableBody>
              {rows.map((o) => (
                <TableRow key={o.id ?? ''} className="cursor-pointer" tabIndex={0} onClick={() => navigate(`/messaging/orders/${o.id}`)} onKeyDown={(ev) => ev.key === 'Enter' && navigate(`/messaging/orders/${o.id}`)}>
                  <TableCell className="whitespace-nowrap text-xs text-muted-foreground">{dateTimeDMY(o.created_at)}</TableCell>
                  <TableCell>{o.customer_name ? <><span className="font-medium">{o.customer_name}</span><div className="text-xs text-muted-foreground">{o.customer_town}</div></> : <><span className="tabular-nums">{o.from_number}</span><div className="text-xs text-amber-700">unknown number</div></>}</TableCell>
                  <TableCell><Badge variant="outline">{o.source}</Badge></TableCell>
                  <TableCell className="max-w-md"><span className="line-clamp-2 text-xs">{o.raw_text ?? o.transcript ?? (o.audio_url ? 'Voice note' : '')}</span></TableCell>
                  <TableCell className="num">{int(o.line_count)}</TableCell>
                  <TableCell><Badge variant={orderTone[o.status ?? 'new']}>{o.status}</Badge>{o.invoice_no && <div className="text-xs text-muted-foreground">{o.invoice_no}</div>}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {logging && <LogCallDialog onClose={() => setLogging(false)} />}
    </div>
  );
}

function LogCallDialog({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const [customer, setCustomer] = useState<CustomerRow | null>(null);
  const [from, setFrom] = useState('');
  const [text, setText] = useState('');
  const create = useMutation({
    mutationFn: () => createInboundOrder({ customer_id: customer?.id ?? undefined, from: from || customer?.mobile1 || undefined, text, source: 'call' }),
    onSuccess: async (id) => { await qc.invalidateQueries({ queryKey: ['messaging', 'orders'] }); onClose(); navigate(`/messaging/orders/${id}`); },
    onError: (e) => toastError(e, 'Could not log the order'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>Log a phone order</DialogTitle><DialogDescription>Write what the customer asked for; you will pick the items on the next screen.</DialogDescription></DialogHeader>
        <form onSubmit={(ev) => { ev.preventDefault(); if (text.trim()) create.mutate(); }} className="space-y-3">
          <Field label="Customer" htmlFor="lc-cust">
            <Combobox<CustomerRow> id="lc-cust" value={customer} onChange={setCustomer} search={searchCustomers} queryKey="customers-pick" getKey={(c) => c.id ?? ''} getLabel={(c) => `${c.name}${c.town ? ` — ${c.town}` : ''}`} placeholder="Name, mobile or town…" autoFocus eager />
          </Field>
          {!customer && <Field label="Caller's number" htmlFor="lc-from"><Input id="lc-from" value={from} onChange={(e) => setFrom(e.target.value)} placeholder="10 digits" /></Field>}
          <Field label="What they asked for" htmlFor="lc-text"><Textarea id="lc-text" rows={3} value={text} onChange={(e) => setText(e.target.value)} placeholder="5 boxes of 8, 2 boxes mysoor pak…" /></Field>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" disabled={create.isPending || !text.trim()}><Plus /> Add to queue</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
