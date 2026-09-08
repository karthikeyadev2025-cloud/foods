import { useQuery } from '@tanstack/react-query';
import { Download } from 'lucide-react';
import { useState } from 'react';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useDebounced } from '@/hooks/use-debounced';
import { exportToExcel } from '@/lib/export';
import { dateTimeDMY, toISODate } from '@/lib/format';
import { AUDIT_TABLES, auditTableLabel, listStaff, searchAudit, type AuditRow } from '../api';

const ACTIONS = [
  { key: 'INSERT', label: 'Created', tone: 'secondary' },
  { key: 'UPDATE', label: 'Changed', tone: 'outline' },
  { key: 'DELETE', label: 'Deleted', tone: 'destructive' },
  { key: 'RESTORE', label: 'Restored', tone: 'default' },
] as const;
const actionOf = (a: string | null) => ACTIONS.find((x) => x.key === a);

function fmt(v: unknown): string {
  if (v === null || v === undefined) return '—';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}
function asObject(v: unknown): Record<string, unknown> {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

/** Who changed what: the trail written by the database, read-only. */
export function AuditPanel({ compact }: { compact?: boolean }) {
  const today = toISODate();
  const [from, setFrom] = useState(toISODate(new Date(Date.now() - 6 * 86_400_000)));
  const [to, setTo] = useState(today);
  const [table, setTable] = useState('');
  const [actor, setActor] = useState('');
  const [action, setAction] = useState('');
  const [search, setSearch] = useState('');
  const debounced = useDebounced(search);
  const [open, setOpen] = useState<AuditRow | null>(null);
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const rows = useQuery({
    queryKey: ['setup', 'audit', from, to, table, actor, action, debounced],
    queryFn: () => searchAudit({ from, to, table, actor, action, search: debounced, limit: 500 }),
  });
  const list = rows.data ?? [];

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 className={compact ? 'text-base font-semibold' : 'text-lg font-semibold'}>Audit trail</h2>
          <p className="max-w-2xl text-sm text-muted-foreground">
            Every create, change and delete on masters, settings and document headers, written by the database itself.
            A change shows only the fields that moved. Passwords and API keys are never recorded.
          </p>
        </div>
        <Button
          variant="outline"
          size="sm"
          disabled={!list.length}
          onClick={() =>
            exportToExcel(
              'audit',
              list.map((r) => ({
                When: dateTimeDMY(r.created_at),
                Who: r.actor_name ?? 'system',
                Action: actionOf(r.action)?.label ?? r.action,
                Screen: auditTableLabel(r.table_name),
                Row: r.row_id,
                Before: r.before ? JSON.stringify(r.before) : '',
                After: r.after ? JSON.stringify(r.after) : '',
              })),
              'Audit',
            )
          }
        >
          <Download /> Excel
        </Button>
      </div>
      <div className="grid grid-cols-2 gap-2 md:grid-cols-6">
        <Field label="From" htmlFor="au-from">
          <Input id="au-from" type="date" className="h-8" value={from} onChange={(e) => setFrom(e.target.value)} />
        </Field>
        <Field label="To" htmlFor="au-to">
          <Input id="au-to" type="date" className="h-8" value={to} onChange={(e) => setTo(e.target.value)} />
        </Field>
        <Field label="Screen" htmlFor="au-table">
          <NativeSelect id="au-table" className="h-8" value={table} onChange={(e) => setTable(e.target.value)}>
            <option value="">All</option>
            {AUDIT_TABLES.map((t) => (
              <option key={t.key} value={t.key}>
                {t.label}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="Who" htmlFor="au-actor">
          <NativeSelect id="au-actor" className="h-8" value={actor} onChange={(e) => setActor(e.target.value)}>
            <option value="">Anyone</option>
            {(staff.data ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.full_name}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="Action" htmlFor="au-action">
          <NativeSelect id="au-action" className="h-8" value={action} onChange={(e) => setAction(e.target.value)}>
            <option value="">All</option>
            {ACTIONS.map((a) => (
              <option key={a.key} value={a.key}>
                {a.label}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="Text" htmlFor="au-search">
          <Input id="au-search" type="search" className="h-8" placeholder="name, number, id…" value={search} onChange={(e) => setSearch(e.target.value)} />
        </Field>
      </div>
      {rows.isLoading ? (
        <Spinner />
      ) : rows.error ? (
        <p role="alert" className="text-sm text-destructive">
          {rows.error.message}
        </p>
      ) : !list.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">Nothing in this range.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>When</TableHead>
                <TableHead>Who</TableHead>
                <TableHead>Action</TableHead>
                <TableHead>Screen</TableHead>
                <TableHead>What</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {list.map((r) => {
                const a = actionOf(r.action);
                const after = asObject(r.after);
                const before = asObject(r.before);
                const summary =
                  r.action === 'UPDATE'
                    ? Object.keys(after).slice(0, 4).join(', ') + (Object.keys(after).length > 4 ? '…' : '')
                    : (fmt(after.name ?? after.invoice_no ?? after.receipt_no ?? after.full_name ?? after.code ?? before.name ?? before.invoice_no ?? before.full_name ?? before.code ?? r.row_id) ?? '');
                return (
                  <TableRow key={r.id ?? 0} className="cursor-pointer" tabIndex={0} onClick={() => setOpen(r)} onKeyDown={(ev) => ev.key === 'Enter' && setOpen(r)}>
                    <TableCell className="whitespace-nowrap">{dateTimeDMY(r.created_at)}</TableCell>
                    <TableCell>{r.actor_name ?? <span className="text-muted-foreground">system</span>}</TableCell>
                    <TableCell>
                      <Badge variant={a?.tone ?? 'outline'}>{a?.label ?? r.action}</Badge>
                    </TableCell>
                    <TableCell>{auditTableLabel(r.table_name)}</TableCell>
                    <TableCell className="max-w-md truncate text-muted-foreground">{summary}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
          {list.length >= 500 && <p className="p-2 text-xs text-muted-foreground">Showing the latest 500. Narrow the dates or filters to see older rows.</p>}
        </div>
      )}
      {open && <AuditDetail row={open} onClose={() => setOpen(null)} />}
    </section>
  );
}

function AuditDetail({ row, onClose }: { row: AuditRow; onClose: () => void }) {
  const before = asObject(row.before);
  const after = asObject(row.after);
  const keys = Array.from(new Set([...Object.keys(before), ...Object.keys(after)])).sort();
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>
            {actionOf(row.action)?.label ?? row.action} · {auditTableLabel(row.table_name)}
          </DialogTitle>
          <DialogDescription>
            {dateTimeDMY(row.created_at)} · {row.actor_name ?? 'system'} · row {row.row_id}
          </DialogDescription>
        </DialogHeader>
        <div className="max-h-[60vh] overflow-auto rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Field</TableHead>
                <TableHead>Before</TableHead>
                <TableHead>After</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {keys.map((k) => (
                <TableRow key={k}>
                  <TableCell className="font-mono text-xs">{k}</TableCell>
                  <TableCell className="max-w-xs break-words text-xs text-muted-foreground">{fmt(before[k])}</TableCell>
                  <TableCell className="max-w-xs break-words text-xs">{fmt(after[k])}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </DialogContent>
    </Dialog>
  );
}
