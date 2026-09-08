import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Plus, Trash2, Undo2 } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { MasterCrud, type MasterConfig } from '@/components/MasterCrud';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { useDebounced } from '@/hooks/use-debounced';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, dateTimeDMY, round, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { z } from 'zod';
import { getJournalLines, ledgerAccountBook, ledgerAccountsApi, listCashBankAccounts, listJournalEntries, listLedgerAccounts, reverseManualJournal, saveManualJournal, type JournalEntryRow, type LedgerAccountRow } from '../api';

const docLink = (e: JournalEntryRow): string | null => {
  if (!e.ref_id) return null;
  switch (e.ref_table) {
    case 'invoices': return `/invoices/${e.ref_id}`;
    case 'receipts': return `/receipts/${e.ref_id}`;
    case 'purchases': return `/purchases/${e.ref_id}`;
    case 'sales_returns': return `/returns/${e.ref_id}`;
    default: return null;
  }
};

/** T7.3 — every posting, document or manual; a manual entry can be reversed, never edited. */
export function JournalPanel() {
  const perms = usePermissions();
  const canEdit = perms.canEdit('payments');
  const [search, setSearch] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [manualOnly, setManualOnly] = useState(false);
  const debounced = useDebounced(search);
  const entries = useQuery({ queryKey: ['accounts', 'journal', debounced, from, to, manualOnly], queryFn: () => listJournalEntries({ search: debounced, from, to, manualOnly }) });
  const [open, setOpen] = useState<JournalEntryRow | null>(null);
  const [composing, setComposing] = useState(false);
  const rows = entries.data ?? [];
  const onExport = () => exportToExcel('journal', rows.map((e) => ({ 'Entry no.': e.entry_no, Date: dateDMY(e.entry_date), Narration: e.narration, Document: e.doc_no, Amount: toNumber(e.amount), Manual: e.is_manual, Reversed: e.is_reversed, By: e.created_by_name })), 'Journal');

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Entry no., narration, document…" aria-label="Search" className="h-8 w-60" value={search} onChange={(e) => setSearch(e.target.value)} />
        <Input type="date" aria-label="From" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} />
        <Input type="date" aria-label="To" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} />
        <label className="flex items-center gap-1 text-sm"><Checkbox checked={manualOnly} onChange={(e) => setManualOnly(e.target.checked)} /> Manual only</label>
        <span className="ml-auto flex gap-2">
          <Button size="sm" variant="outline" onClick={onExport} disabled={!rows.length}><Download /> Excel</Button>
          {canEdit && <Button size="sm" onClick={() => setComposing(true)}><Plus /> Manual entry</Button>}
        </span>
      </div>
      {entries.isLoading ? <Spinner /> : entries.error ? <p role="alert" className="text-sm text-destructive">{entries.error.message}</p> : !rows.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No entries.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Entry</TableHead><TableHead>Date</TableHead><TableHead>Narration</TableHead><TableHead>Document</TableHead><TableHead className="text-right">Amount</TableHead><TableHead>Kind</TableHead><TableHead>By</TableHead></TableRow></TableHeader>
            <TableBody>
              {rows.map((e) => {
                const link = docLink(e);
                return (
                  <TableRow key={e.id ?? ''} className={cn('cursor-pointer', e.is_reversed && 'text-muted-foreground line-through decoration-muted-foreground/40')} tabIndex={0} onClick={() => setOpen(e)} onKeyDown={(ev) => ev.key === 'Enter' && setOpen(e)}>
                    <TableCell className="font-medium">{e.entry_no}</TableCell>
                    <TableCell>{dateDMY(e.entry_date)}</TableCell>
                    <TableCell className="max-w-md truncate">{e.narration}</TableCell>
                    <TableCell onClick={(ev) => ev.stopPropagation()}>{link ? <Link to={link} className="text-primary hover:underline">{e.doc_no}</Link> : e.doc_no}</TableCell>
                    <TableCell className="num">{amount(e.amount)}</TableCell>
                    <TableCell>{e.reverses_entry_id ? <Badge variant="outline">reversal</Badge> : e.is_manual ? <Badge variant="secondary">manual</Badge> : <Badge variant="outline">{e.ref_table?.replace('_', ' ')}</Badge>}</TableCell>
                    <TableCell className="text-xs text-muted-foreground">{e.created_by_name}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}
      {open && <EntryDialog entry={open} canEdit={canEdit} onClose={() => setOpen(null)} />}
      {composing && <ManualEntryDialog onClose={() => setComposing(false)} />}
    </div>
  );
}

function EntryDialog({ entry, canEdit, onClose }: { entry: JournalEntryRow; canEdit: boolean; onClose: () => void }) {
  const qc = useQueryClient();
  const lines = useQuery({ queryKey: ['accounts', 'journal-lines', entry.id], queryFn: () => getJournalLines(entry.id ?? '') });
  const reverse = useMutation({
    mutationFn: () => reverseManualJournal(entry.id ?? '', toISODate()),
    onSuccess: async () => { toast({ title: 'Entry reversed' }); await qc.invalidateQueries({ queryKey: ['accounts'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not reverse'),
  });
  const ls = lines.data ?? [];
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{entry.entry_no} · {dateDMY(entry.entry_date)}</DialogTitle>
          <DialogDescription>{entry.narration}{entry.created_by_name ? ` — ${entry.created_by_name}, ${dateTimeDMY(entry.created_at)}` : ''}</DialogDescription>
        </DialogHeader>
        {lines.isLoading ? <Spinner /> : (
          <Table>
            <TableHeader><TableRow><TableHead>Account</TableHead><TableHead>Narration</TableHead><TableHead className="text-right">Debit</TableHead><TableHead className="text-right">Credit</TableHead></TableRow></TableHeader>
            <TableBody>
              {ls.map((l) => (
                <TableRow key={l.id ?? ''}>
                  <TableCell className={cn(toNumber(l.credit) > 0 && 'pl-8')}><span className="font-medium">{l.account_name}</span> <span className="text-xs text-muted-foreground">{l.account_code}{l.cash_account_name ? ` · ${l.cash_account_name}` : ''}</span></TableCell>
                  <TableCell className="text-muted-foreground">{l.narration}</TableCell>
                  <TableCell className="num">{toNumber(l.debit) ? amount(l.debit) : ''}</TableCell>
                  <TableCell className="num">{toNumber(l.credit) ? amount(l.credit) : ''}</TableCell>
                </TableRow>
              ))}
            </TableBody>
            <TableFooter><TableRow><TableCell colSpan={2} className="text-right">Total</TableCell><TableCell className="num">{amount(ls.reduce((s, l) => s + toNumber(l.debit), 0))}</TableCell><TableCell className="num">{amount(ls.reduce((s, l) => s + toNumber(l.credit), 0))}</TableCell></TableRow></TableFooter>
          </Table>
        )}
        <DialogFooter>
          {canEdit && entry.is_manual && !entry.is_reversed && !entry.reverses_entry_id && <Button variant="destructive" onClick={() => reverse.mutate()} disabled={reverse.isPending}><Undo2 /> Reverse this entry</Button>}
          <Button variant="outline" onClick={onClose}>Close</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

interface Line { key: number; account_id: string; debit: string; credit: string; narration: string; cash_account_id: string }

function ManualEntryDialog({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const accounts = useQuery({ queryKey: ['accounts', 'ledger'], queryFn: listLedgerAccounts });
  const cashBank = useQuery({ queryKey: ['accounts', 'cash_bank'], queryFn: listCashBankAccounts });
  const [date, setDate] = useState(toISODate());
  const [narration, setNarration] = useState('');
  const [lines, setLines] = useState<Line[]>([{ key: 1, account_id: '', debit: '', credit: '', narration: '', cash_account_id: '' }, { key: 2, account_id: '', debit: '', credit: '', narration: '', cash_account_id: '' }]);
  const dr = round(lines.reduce((s, l) => s + toNumber(l.debit), 0), 2);
  const cr = round(lines.reduce((s, l) => s + toNumber(l.credit), 0), 2);
  const codeOf = (id: string) => accounts.data?.find((a) => a.id === id)?.code ?? '';
  const update = (key: number, patch: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  const save = useMutation({
    mutationFn: () => {
      if (!narration.trim()) throw new Error('Say what this entry is for');
      if (dr !== cr) throw new Error(`Debits ${amount(dr)} and credits ${amount(cr)} must match`);
      return saveManualJournal({ entry_date: date, narration, lines: lines.filter((l) => l.account_id && (toNumber(l.debit) || toNumber(l.credit))).map((l) => ({ account_id: l.account_id, debit: toNumber(l.debit), credit: toNumber(l.credit), narration: l.narration || null, cash_account_id: l.cash_account_id || null })) });
    },
    onSuccess: async () => { toast({ title: 'Journal entry posted' }); await qc.invalidateQueries({ queryKey: ['accounts'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not post'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-3xl">
        <DialogHeader><DialogTitle>Manual journal entry</DialogTitle><DialogDescription>For what no document covers: capital, bank interest, depreciation, corrections. A Cash / Bank line names the account so the book moves too.</DialogDescription></DialogHeader>
        <form onSubmit={(ev) => { ev.preventDefault(); save.mutate(); }} className="space-y-3">
          <div className="grid grid-cols-3 gap-3">
            <Field label="Date" htmlFor="mj-date"><Input id="mj-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
            <Field label="Narration" htmlFor="mj-narr" className="col-span-2"><Input id="mj-narr" value={narration} onChange={(e) => setNarration(e.target.value)} autoFocus placeholder="Owner introduced capital" /></Field>
          </div>
          <Table>
            <TableHeader><TableRow><TableHead>Account</TableHead><TableHead className="w-40">Cash / bank a/c</TableHead><TableHead className="w-28 text-right">Debit</TableHead><TableHead className="w-28 text-right">Credit</TableHead><TableHead>Line note</TableHead><TableHead className="w-8" /></TableRow></TableHeader>
            <TableBody>
              {lines.map((l) => {
                const code = codeOf(l.account_id);
                const money = code === 'CASH' || code === 'BANK';
                return (
                  <TableRow key={l.key}>
                    <TableCell>
                      <NativeSelect aria-label="Account" className="h-8" value={l.account_id} onChange={(e) => update(l.key, { account_id: e.target.value, cash_account_id: '' })}>
                        <option value="">— account —</option>
                        {(accounts.data ?? []).filter((a) => a.is_active).map((a) => <option key={a.id ?? ''} value={a.id ?? ''}>{a.name} ({a.type})</option>)}
                      </NativeSelect>
                    </TableCell>
                    <TableCell>
                      {money && (
                        <NativeSelect aria-label="Cash or bank account" className="h-8" value={l.cash_account_id} onChange={(e) => update(l.key, { cash_account_id: e.target.value })}>
                          <option value="">— which —</option>
                          {(cashBank.data ?? []).filter((a) => a.is_active && ((code === 'CASH') === (a.kind === 'cash'))).map((a) => <option key={a.id ?? ''} value={a.id ?? ''}>{a.name}</option>)}
                        </NativeSelect>
                      )}
                    </TableCell>
                    <TableCell><Input type="number" step="0.01" className="num h-8" aria-label="Debit" value={l.debit} onChange={(e) => update(l.key, { debit: e.target.value, credit: e.target.value ? '' : l.credit })} /></TableCell>
                    <TableCell><Input type="number" step="0.01" className="num h-8" aria-label="Credit" value={l.credit} onChange={(e) => update(l.key, { credit: e.target.value, debit: e.target.value ? '' : l.debit })} /></TableCell>
                    <TableCell><Input className="h-8" aria-label="Line note" value={l.narration} onChange={(e) => update(l.key, { narration: e.target.value })} /></TableCell>
                    <TableCell><Button type="button" size="sm" variant="ghost" aria-label="Remove line" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} disabled={lines.length <= 2}><Trash2 /></Button></TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
            <TableFooter><TableRow><TableCell colSpan={2} className="text-right">Total</TableCell><TableCell className="num">{amount(dr)}</TableCell><TableCell className={cn('num', dr !== cr && 'text-destructive')}>{amount(cr)}</TableCell><TableCell colSpan={2}>{dr !== cr && <span className="text-xs text-destructive">difference {amount(Math.abs(dr - cr))}</span>}</TableCell></TableRow></TableFooter>
          </Table>
          <Button type="button" size="sm" variant="outline" onClick={() => setLines((ls) => [...ls, { key: Date.now(), account_id: '', debit: '', credit: '', narration: '', cash_account_id: '' }])}><Plus /> Line</Button>
          <DialogFooter><Button type="button" variant="outline" onClick={onClose}>Cancel</Button><Button type="submit" disabled={save.isPending || dr !== cr || dr === 0}>{save.isPending ? 'Posting…' : 'Post entry'}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

// ------------------------------------------------------------------
// Chart of accounts
// ------------------------------------------------------------------
const ACCOUNT_TYPES = [
  { value: 'asset', label: 'Asset' },
  { value: 'liability', label: 'Liability' },
  { value: 'income', label: 'Income' },
  { value: 'expense', label: 'Expense' },
  { value: 'equity', label: 'Equity' },
] as const;

const ledgerSchema = z.object({
  code: z.string().trim().max(30),
  name: z.string().trim().min(1, 'Name is required').max(80),
  type: z.enum(['asset', 'liability', 'income', 'expense', 'equity']),
  is_active: z.boolean(),
});
type LedgerInput = z.infer<typeof ledgerSchema>;
type LedgerRow = LedgerAccountRow & { id: string };

export function ChartPanel() {
  const perms = usePermissions();
  const [ledger, setLedger] = useState<LedgerRow | null>(null);
  const config: MasterConfig<LedgerRow, LedgerInput> = {
    key: 'ledger_accounts',
    title: 'Chart of accounts',
    singular: 'Account',
    exportName: 'chart-of-accounts',
    description: 'Documents post to the system accounts by code; those can be renamed but not deleted. Add your own heads (rent, electricity, interest) for manual entries. Click a row to see its ledger.',
    columns: [
      { key: 'code', label: 'Code' },
      { key: 'name', label: 'Name' },
      { key: 'type', label: 'Type' },
      { key: 'balance', label: 'Balance (Dr +)', align: 'right', render: (r) => <button type="button" className="tabular-nums hover:underline" onClick={(ev) => { ev.stopPropagation(); setLedger(r); }}>{amount(r.balance)}</button> },
      { key: 'is_system', label: 'System' },
      { key: 'is_active', label: 'Active' },
    ],
    fields: [
      { name: 'name', label: 'Name', autoFocus: true },
      { name: 'code', label: 'Code (optional)', half: true, placeholder: 'RENT' },
      { name: 'type', label: 'Type', type: 'select', options: ACCOUNT_TYPES, half: true },
      { name: 'is_active', label: 'Active', type: 'checkbox' },
    ],
    schema: ledgerSchema,
    defaults: { code: '', name: '', type: 'expense', is_active: true },
    toForm: (r) => ({ code: r.code ?? '', name: r.name ?? '', type: r.type ?? 'expense', is_active: r.is_active ?? true }),
    rowLabel: (r) => r.name ?? '',
    list: async () => (await ledgerAccountsApi.list()).map((r) => ({ ...r, id: r.id ?? '' })),
    create: (v) => ledgerAccountsApi.create({ ...v, code: v.code ? v.code.toUpperCase() : null }),
    update: (id, v) => ledgerAccountsApi.update(id, { name: v.name, is_active: v.is_active, ...(v.code ? { code: v.code.toUpperCase() } : {}) }),
    remove: ledgerAccountsApi.remove,
    canEdit: perms.canEdit('payments'),
    canDelete: perms.canDelete('payments'),
  };
  return (
    <div className="space-y-4">
      <MasterCrud config={config} />
      {ledger && <LedgerBookDialog account={ledger} onClose={() => setLedger(null)} />}
    </div>
  );
}

function LedgerBookDialog({ account, onClose }: { account: LedgerRow; onClose: () => void }) {
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const book = useQuery({ queryKey: ['accounts', 'ledger-book', account.id, from, to], queryFn: () => ledgerAccountBook(account.id, from, to) });
  const rows = book.data ?? [];
  const onExport = () => exportToExcel(`ledger-${account.code ?? account.name}`, rows.map((r) => ({ Date: r.entry_date ? dateDMY(r.entry_date) : '', Entry: r.entry_no ?? '', Document: r.doc_no ?? '', Narration: r.narration ?? '', Debit: toNumber(r.debit), Credit: toNumber(r.credit), Balance: toNumber(r.balance) })), 'Ledger');
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-3xl">
        <DialogHeader><DialogTitle>{account.name} <span className="text-sm font-normal text-muted-foreground">{account.code} · {account.type}</span></DialogTitle></DialogHeader>
        <div className="flex flex-wrap items-end gap-2">
          <Field label="From" htmlFor="lb-from"><Input id="lb-from" type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
          <Field label="To" htmlFor="lb-to"><Input id="lb-to" type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
          <Button size="sm" variant="outline" className="ml-auto" onClick={onExport} disabled={!rows.length}><Download /> Excel</Button>
        </div>
        {book.isLoading ? <Spinner /> : (
          <div className="max-h-[60vh] overflow-auto rounded-md border">
            <Table>
              <TableHeader><TableRow><TableHead>Date</TableHead><TableHead>Entry</TableHead><TableHead>Document</TableHead><TableHead>Narration</TableHead><TableHead className="text-right">Debit</TableHead><TableHead className="text-right">Credit</TableHead><TableHead className="text-right">Balance</TableHead></TableRow></TableHeader>
              <TableBody>
                {rows.map((r, i) => (
                  <TableRow key={r.line_id ?? `o${i}`} className={cn(!r.line_id && 'bg-muted/40')}>
                    <TableCell>{r.entry_date ? dateDMY(r.entry_date) : ''}</TableCell><TableCell className="font-medium">{r.entry_no}</TableCell><TableCell>{r.doc_no}</TableCell><TableCell className="text-muted-foreground">{r.narration}</TableCell>
                    <TableCell className="num">{toNumber(r.debit) ? amount(r.debit) : ''}</TableCell><TableCell className="num">{toNumber(r.credit) ? amount(r.credit) : ''}</TableCell><TableCell className="num font-medium">{amount(r.balance)}</TableCell>
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
