import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { PhoneCall, Plus, Send, X } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
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
import { routesApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { dateTimeDMY, int } from '@/lib/format';
import { broadcastRecipients, cancelBroadcast, createBroadcast, listBroadcasts, queueBroadcast, templatesApi, type BroadcastRow } from '../api';
import { broadcastSchema, type BroadcastInput } from '../schema';

const KIND_LABEL: Record<string, string> = { new_stock: 'New stock', catalog: 'Catalog', custom: 'Message', order_call: 'Order calls' };

function segmentText(seg: unknown): string {
  const s = (seg && typeof seg === 'object' ? seg : {}) as Record<string, unknown>;
  const parts: string[] = [];
  if (s.town) parts.push(`town ${String(s.town)}`);
  if (s.route_id) parts.push('one route');
  if (s.bought_within_days) parts.push(`${s.bought_item_id ? 'bought this item' : 'bought'} in ${String(s.bought_within_days)} d`);
  return parts.length ? parts.join(' · ') : 'everyone opted in';
}

/**
 * Compose a broadcast to a segment, see who it reaches, then send or leave it pending.
 * Used for catalogs (Catalogs tab → Push) and free-text messages.
 */
export function BroadcastDialog({ open, onClose, kind, catalogId, catalogName }: { open: boolean; onClose: () => void; kind: 'catalog' | 'custom' | 'order_call'; catalogId?: string; catalogName?: string }) {
  const qc = useQueryClient();
  const templates = useQuery({ queryKey: ['setup', 'message_templates'], queryFn: templatesApi.list });
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list });
  const [created, setCreated] = useState<string | null>(null);
  const recipients = useQuery({ queryKey: ['messaging', 'broadcast-recipients', created], queryFn: () => broadcastRecipients(created ?? ''), enabled: Boolean(created) });
  const form = useForm<BroadcastInput>({ resolver: zodResolver(broadcastSchema), defaultValues: { template_id: '', body: '', route_id: '', town: '', bought_within_days: 0 } });

  const create = useMutation({
    mutationFn: (v: BroadcastInput) => {
      if (kind === 'custom' && !v.template_id && !v.body) throw new Error('Type the message or pick a template');
      return createBroadcast({
        kind,
        catalog_id: catalogId,
        template_id: v.template_id || undefined,
        body: v.body || undefined,
        segment: { route_id: v.route_id || undefined, town: v.town || undefined, bought_within_days: v.bought_within_days || undefined },
        note: kind === 'catalog' ? `Catalog ${catalogName ?? ''}` : kind === 'order_call' ? `Order calls ${new Date().toLocaleDateString('en-IN')}` : v.body.slice(0, 60),
      });
    },
    onSuccess: (id) => setCreated(id),
    onError: (e) => toastError(e, 'Could not create the broadcast'),
  });
  const send = useMutation({
    mutationFn: () => queueBroadcast(created ?? ''),
    onSuccess: async (n) => {
      toast({ title: kind === 'order_call' ? `Calls queued for ${n} customer${n === 1 ? '' : 's'}` : `Queued for ${n} customer${n === 1 ? '' : 's'}`, description: kind === 'order_call' ? 'Placed within minutes while calls are switched on, outside quiet hours. Orders the bot hears land in the Orders tab.' : 'Sent within minutes, outside quiet hours and within the daily cap.' });
      await qc.invalidateQueries({ queryKey: ['messaging'] });
      close();
    },
    onError: (e) => toastError(e, 'Could not send'),
  });
  const close = () => {
    setCreated(null);
    form.reset();
    onClose();
  };
  const purposeTemplates = (templates.data ?? []).filter((t) => t.is_active && (kind === 'order_call' ? t.purpose === 'custom' && t.channel === 'ivr_call' : t.purpose === kind && t.channel !== 'ivr_call'));
  const e = form.formState.errors;

  return (
    <Dialog open={open} onOpenChange={(o) => !o && close()}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>{kind === 'catalog' ? `Push catalog ${catalogName ?? ''}` : kind === 'order_call' ? 'Call customers for their orders' : 'Message a segment'}</DialogTitle>
          <DialogDescription>{kind === 'order_call' ? 'Hey Nikki rings each customer, reads the order script in their language and takes the order in conversation. Whatever it hears waits in the Orders tab for you to confirm — nothing is billed by itself.' : 'Only customers with a mobile and WhatsApp opt-in are included. Every message is logged.'}</DialogDescription>
        </DialogHeader>
        {!created ? (
          <form onSubmit={form.handleSubmit((v) => create.mutate(v))} className="grid grid-cols-2 gap-3">
            <Field label={kind === 'order_call' ? 'Call script' : 'Template'} htmlFor="bc-tpl" className="col-span-2" error={e.template_id?.message}>
              <NativeSelect id="bc-tpl" {...form.register('template_id')}>
                <option value="">{kind === 'custom' ? '— none, type below —' : '— by customer language —'}</option>
                {purposeTemplates.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </NativeSelect>
            </Field>
            {kind === 'custom' && (
              <Field label="Message" htmlFor="bc-body" className="col-span-2" error={e.body?.message} help="{{name}}, {{org}} and {{outstanding}} are filled per customer.">
                <Textarea id="bc-body" rows={3} {...form.register('body')} />
              </Field>
            )}
            <Field label="Route" htmlFor="bc-route">
              <NativeSelect id="bc-route" {...form.register('route_id')}>
                <option value="">All routes</option>
                {(routes.data ?? []).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
              </NativeSelect>
            </Field>
            <Field label="Town" htmlFor="bc-town" error={e.town?.message}><Input id="bc-town" placeholder="any" {...form.register('town')} /></Field>
            <Field label="Bought anything in the last (days)" htmlFor="bc-days" help="0 = no purchase filter" error={e.bought_within_days?.message}>
              <Input id="bc-days" type="number" className="num" {...form.register('bought_within_days')} />
            </Field>
            <DialogFooter className="col-span-2 pt-2">
              <Button type="button" variant="outline" onClick={close}>Cancel</Button>
              <Button type="submit" disabled={create.isPending}>{create.isPending ? 'Preparing…' : 'Preview recipients'}</Button>
            </DialogFooter>
          </form>
        ) : (
          <div className="space-y-3">
            {recipients.isLoading ? <Spinner /> : recipients.error ? (
              <p role="alert" className="text-sm text-destructive">{recipients.error.message}</p>
            ) : (
              <>
                <p className="text-sm"><strong>{int(recipients.data?.length ?? 0)}</strong> customer{recipients.data?.length === 1 ? '' : 's'} will receive this.</p>
                {recipients.data && recipients.data.length > 0 && (
                  <div className="max-h-56 overflow-auto rounded-md border">
                    <Table>
                      <TableBody>
                        {recipients.data.map((r) => (
                          <TableRow key={r.customer_id}><TableCell className="font-medium">{r.name}</TableCell><TableCell>{r.town}</TableCell><TableCell className="tabular-nums">{r.mobile1}</TableCell></TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </div>
                )}
              </>
            )}
            <DialogFooter>
              <Button type="button" variant="outline" onClick={close}>Leave pending</Button>
              <Button type="button" onClick={() => send.mutate()} disabled={send.isPending || !recipients.data?.length}><Send /> Send to {int(recipients.data?.length ?? 0)}</Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

export function BroadcastsPanel() {
  const qc = useQueryClient();
  const perms = usePermissions();
  const canEdit = perms.canEdit('messaging');
  const rows = useQuery({ queryKey: ['messaging', 'broadcasts'], queryFn: listBroadcasts });
  const [composing, setComposing] = useState<'custom' | 'order_call' | null>(null);
  const invalidate = () => qc.invalidateQueries({ queryKey: ['messaging'] });
  const send = useMutation({
    mutationFn: (id: string) => queueBroadcast(id),
    onSuccess: async (n) => { toast({ title: `Queued for ${n}` }); await invalidate(); },
    onError: (e) => toastError(e, 'Could not send'),
  });
  const cancel = useMutation({
    mutationFn: (id: string) => cancelBroadcast(id),
    onSuccess: async () => { toast({ title: 'Broadcast cancelled' }); await invalidate(); },
    onError: (e) => toastError(e, 'Could not cancel'),
  });
  const list = rows.data ?? [];
  const pending = list.filter((b) => b.status === 'pending');

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <p className="text-sm text-muted-foreground">New-stock broadcasts appear here when production or a purchase lifts an item above its threshold (New stock tab). Pending ones wait for you.</p>
        {canEdit && (
          <span className="ml-auto flex gap-2">
            <Button size="sm" variant="outline" onClick={() => setComposing('order_call')}><PhoneCall /> Call for orders</Button>
            <Button size="sm" onClick={() => setComposing('custom')}><Plus /> Message a segment</Button>
          </span>
        )}
      </div>
      {pending.length > 0 && <Badge>{pending.length} pending</Badge>}
      {rows.isLoading ? <Spinner /> : rows.error ? (
        <p role="alert" className="text-sm text-destructive">{rows.error.message}</p>
      ) : !list.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No broadcasts yet.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>When</TableHead><TableHead>Kind</TableHead><TableHead>What</TableHead><TableHead>To</TableHead><TableHead className="text-right">Recipients</TableHead><TableHead className="text-right">Sent / failed</TableHead><TableHead>Status</TableHead><TableHead>By</TableHead><TableHead /></TableRow></TableHeader>
            <TableBody>
              {list.map((b) => <BroadcastLine key={b.id ?? ''} b={b} canEdit={canEdit} onSend={() => send.mutate(b.id ?? '')} onCancel={() => cancel.mutate(b.id ?? '')} busy={send.isPending || cancel.isPending} />)}
            </TableBody>
          </Table>
        </div>
      )}
      {composing && <BroadcastDialog open onClose={() => setComposing(null)} kind={composing} />}
    </div>
  );
}

function BroadcastLine({ b, canEdit, onSend, onCancel, busy }: { b: BroadcastRow; canEdit: boolean; onSend: () => void; onCancel: () => void; busy: boolean }) {
  return (
    <TableRow className={b.status === 'pending' ? 'bg-amber-50/50' : undefined}>
      <TableCell className="text-xs text-muted-foreground">{dateTimeDMY(b.created_at)}</TableCell>
      <TableCell><Badge variant="outline">{KIND_LABEL[b.kind ?? ''] ?? b.kind}</Badge></TableCell>
      <TableCell>{b.kind === 'new_stock' ? `${b.item_code} — ${b.item_name}` : b.kind === 'catalog' ? b.catalog_name : b.note}<div className="text-xs text-muted-foreground">{b.kind === 'order_call' ? `voice · ${b.template_name ?? 'script by language'}` : (b.template_name ?? (b.body ? 'free text' : 'by language'))}</div></TableCell>
      <TableCell className="text-xs text-muted-foreground">{segmentText(b.segment)}</TableCell>
      <TableCell className="num">{b.status === 'queued' ? int(b.recipients) : ''}</TableCell>
      <TableCell className="num">{b.status === 'queued' ? `${int(b.sent_count)} / ${int(b.failed_count)}` : ''}</TableCell>
      <TableCell><Badge variant={b.status === 'pending' ? 'default' : b.status === 'cancelled' ? 'destructive' : 'secondary'}>{b.status}</Badge></TableCell>
      <TableCell className="text-xs text-muted-foreground">{b.created_by_name ?? 'system'}</TableCell>
      <TableCell className="whitespace-nowrap text-right">
        {canEdit && b.status === 'pending' && (
          <>
            <Button size="sm" onClick={onSend} disabled={busy}><Send /> Send</Button>{' '}
            <Button size="sm" variant="ghost" onClick={onCancel} disabled={busy} aria-label="Cancel broadcast"><X /></Button>
          </>
        )}
      </TableCell>
    </TableRow>
  );
}
