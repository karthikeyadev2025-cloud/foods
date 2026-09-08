import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Send } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { useDebounced } from '@/hooks/use-debounced';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { dateTimeDMY } from '@/lib/format';
import { sendQueuedNow } from '@/lib/nikki';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { listAllMessages, listMessages, statusTone, type MessageRow, type MsgPurpose, type MsgStatus } from '../api';
import { PURPOSES } from '../schema';

const STATUSES: MsgStatus[] = ['queued', 'sent', 'delivered', 'read', 'failed'];

export function LogPanel() {
  const qc = useQueryClient();
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState<MsgStatus | ''>('');
  const [purpose, setPurpose] = useState<MsgPurpose | ''>('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const debounced = useDebounced(search);
  const filters = { search: debounced, status, purpose, from, to };
  const messages = useQuery({ queryKey: ['messaging', 'log', { ...filters, page, pageSize }], queryFn: () => listMessages({ ...filters, page, pageSize }), placeholderData: keepPreviousData });
  const sendNow = useMutation({
    mutationFn: sendQueuedNow,
    onSuccess: async (r) => { toast({ title: `${r.sent} sent, ${r.failed} failed`, description: r.skipped_reason }); await qc.invalidateQueries({ queryKey: ['messaging', 'log'] }); },
    onError: (e) => toastError(e, 'Could not send'),
  });

  const onExport = async () => {
    try {
      const rows = await listAllMessages(filters);
      exportToExcel('message-log', rows.map((m) => ({ When: dateTimeDMY(m.created_at), Customer: m.customer_name, Mobile: m.to_number, Purpose: m.purpose, Template: m.template_name, Status: m.status, Message: m.body, Error: m.error, Sent: m.sent_at ? dateTimeDMY(m.sent_at) : '', Delivered: m.delivered_at ? dateTimeDMY(m.delivered_at) : '', Read: m.read_at ? dateTimeDMY(m.read_at) : '' })), 'Messages');
    } catch (err) {
      toastError(err, 'Export failed');
    }
  };

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Customer, mobile, text…" aria-label="Search messages" className="h-8 w-56" value={search} onChange={(e) => { setSearch(e.target.value); setPage(1); }} />
        <NativeSelect aria-label="Status" className="h-8 w-36" value={status} onChange={(e) => { setStatus(e.target.value as MsgStatus | ''); setPage(1); }}>
          <option value="">All statuses</option>
          {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
        </NativeSelect>
        <NativeSelect aria-label="Purpose" className="h-8 w-48" value={purpose} onChange={(e) => { setPurpose(e.target.value as MsgPurpose | ''); setPage(1); }}>
          <option value="">All purposes</option>
          {PURPOSES.map((p) => <option key={p.value} value={p.value}>{p.label}</option>)}
        </NativeSelect>
        <Input type="date" aria-label="From" className="h-8 w-40" value={from} onChange={(e) => { setFrom(e.target.value); setPage(1); }} />
        <Input type="date" aria-label="To" className="h-8 w-40" value={to} onChange={(e) => { setTo(e.target.value); setPage(1); }} />
        <span className="ml-auto flex gap-2">
          {perms.canEdit('messaging') && <Button size="sm" onClick={() => sendNow.mutate()} disabled={sendNow.isPending}><Send /> Send queued now</Button>}
          <Button size="sm" variant="outline" onClick={onExport} disabled={!messages.data?.total}><Download /> Excel</Button>
        </span>
      </div>
      {messages.isLoading ? <Spinner /> : messages.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load: {messages.error.message}</p>
      ) : !messages.data?.rows.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No messages match.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>When</TableHead><TableHead>Customer</TableHead><TableHead>Mobile</TableHead><TableHead>Purpose</TableHead><TableHead>Message</TableHead><TableHead>Status</TableHead><TableHead>Delivery</TableHead></TableRow></TableHeader>
            <TableBody>{messages.data.rows.map((m) => <LogLine key={m.id ?? ''} m={m} />)}</TableBody>
          </Table>
        </div>
      )}
      {messages.data && <Pager page={page} pageSize={pageSize} total={messages.data.total} onPage={setPage} onPageSize={(n) => { setPageSize(n); setPage(1); }} />}
    </div>
  );
}

function LogLine({ m }: { m: MessageRow }) {
  const ref = m.ref_table === 'invoices' ? `/invoices/${m.ref_id}` : m.ref_table === 'receipts' ? `/receipts/${m.ref_id}` : null;
  return (
    <TableRow>
      <TableCell className="whitespace-nowrap text-xs text-muted-foreground">{dateTimeDMY(m.created_at)}</TableCell>
      <TableCell className="font-medium">{m.customer_name ?? '—'}<div className="text-xs font-normal text-muted-foreground">{m.town}</div></TableCell>
      <TableCell className="tabular-nums">{m.to_number}</TableCell>
      <TableCell><Badge variant="outline">{m.channel === 'ivr_call' ? '📞 ' : ''}{m.purpose?.replace('_', ' ')}</Badge>{m.rule_name && <div className="text-xs text-muted-foreground">{m.rule_name}</div>}{ref && <div className="text-xs"><Link to={ref} className="text-primary hover:underline">open document</Link></div>}</TableCell>
      <TableCell className="max-w-md">
        <span className="line-clamp-2 text-xs">{m.body}</span>
        {m.media_url && <a href={m.media_url} target="_blank" rel="noreferrer" className="text-xs text-primary hover:underline">attachment</a>}
        {m.channel === 'ivr_call' && (m.call_note || m.transcript || m.recording_url) && (
          <div className="mt-1 text-xs">
            {m.call_note && <div className="text-emerald-700">{m.call_note}{m.promised_on ? ` (${dateTimeDMY(m.promised_on).slice(0, 10)})` : ''}</div>}
            {m.transcript && <div className="line-clamp-2 text-muted-foreground">“{m.transcript}”</div>}
            {m.recording_url && <a href={m.recording_url} target="_blank" rel="noreferrer" className="text-primary hover:underline">recording</a>}
          </div>
        )}
      </TableCell>
      <TableCell><Badge variant={statusTone[m.status ?? 'queued']}>{m.channel === 'ivr_call' ? (m.call_status ?? m.status) : m.status}</Badge>{m.error && <div className="max-w-40 text-xs text-destructive">{m.error}</div>}</TableCell>
      <TableCell className="whitespace-nowrap text-xs text-muted-foreground">
        {m.channel === 'ivr_call' && m.call_duration ? `${m.call_duration}s · ` : ''}
        {m.read_at ? `${m.channel === 'ivr_call' ? 'answered' : 'read'} ${dateTimeDMY(m.read_at)}` : m.delivered_at ? `${m.channel === 'ivr_call' ? 'answered' : 'delivered'} ${dateTimeDMY(m.delivered_at)}` : m.sent_at ? `${m.channel === 'ivr_call' ? 'placed' : 'sent'} ${dateTimeDMY(m.sent_at)}` : m.not_before ? `retry ${dateTimeDMY(m.not_before)}` : `attempt ${m.attempts ?? 0}`}
      </TableCell>
    </TableRow>
  );
}
