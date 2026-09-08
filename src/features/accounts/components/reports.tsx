import { useQuery } from '@tanstack/react-query';
import { Download, Printer } from 'lucide-react';
import { Fragment, useState, type ReactNode } from 'react';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe } from '@/features/auth/hooks';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, dateTimeDMY, int, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { balanceSheet, cashFlow, dayBook, itemProfit, profitAndLoss, trialBalance } from '../api';

function monthStart(): string {
  const d = new Date();
  return toISODate(new Date(d.getFullYear(), d.getMonth(), 1));
}
function fyStart(): string {
  const d = new Date();
  return toISODate(new Date(d.getMonth() >= 3 ? d.getFullYear() : d.getFullYear() - 1, 3, 1));
}

function Toolbar({ children, onExport, disabled }: { children: ReactNode; onExport: () => void; disabled: boolean }) {
  return (
    <div className="no-print flex flex-wrap items-end gap-2">
      {children}
      <span className="ml-auto flex gap-2 pb-1">
        <Button size="sm" variant="outline" onClick={() => window.print()} disabled={disabled}><Printer /> Print</Button>
        <Button size="sm" variant="outline" onClick={onExport} disabled={disabled}><Download /> Excel</Button>
      </span>
    </div>
  );
}
function PrintTitle({ title, range }: { title: string; range: string }) {
  const me = useMe();
  return <div className="hidden print:block"><h2 className="text-lg font-semibold">{me.data?.org_name}</h2><p className="text-sm">{title} · {range}</p></div>;
}
function Status({ isLoading, error, empty, children }: { isLoading: boolean; error: Error | null; empty: boolean; children: ReactNode }) {
  if (isLoading) return <Spinner />;
  if (error) return <p role="alert" className="text-sm text-destructive">Could not load: {error.message}</p>;
  if (empty) return <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">Nothing in this range.</p>;
  return <div className="overflow-x-auto rounded-md border">{children}</div>;
}
const sum = <T,>(rows: T[], f: (r: T) => number | string | null | undefined) => rows.reduce((s, r) => s + toNumber(f(r)), 0);
const useOrg = () => useMe().data?.org_id ?? '';

export function TrialBalanceReport() {
  const orgId = useOrg();
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const q = useQuery({ queryKey: ['accounts', 'tb', orgId, from, to], queryFn: () => trialBalance(orgId, from, to), enabled: Boolean(orgId) });
  const rows = q.data ?? [];
  const diff = sum(rows, (r) => r.closing);
  return (
    <div className="space-y-3">
      <Toolbar disabled={!rows.length} onExport={() => exportToExcel('trial-balance', rows.map((r) => ({ Code: r.code, Account: r.name, Type: r.type, Opening: toNumber(r.opening), Debit: toNumber(r.debit), Credit: toNumber(r.credit), Closing: toNumber(r.closing) })), 'Trial balance')}>
        <Field label="From" htmlFor="tb-from"><Input id="tb-from" type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label="To" htmlFor="tb-to"><Input id="tb-to" type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
        <Badge variant={Math.abs(diff) < 0.005 ? 'secondary' : 'destructive'} className="mb-1">{Math.abs(diff) < 0.005 ? 'balances' : `off by ${amount(diff)}`}</Badge>
      </Toolbar>
      <PrintTitle title="Trial balance" range={from || to ? `${from ? dateDMY(from) : 'start'} to ${to ? dateDMY(to) : 'today'}` : 'all dates'} />
      <Status isLoading={q.isLoading} error={q.error} empty={!rows.length}>
        <Table>
          <TableHeader><TableRow><TableHead>Code</TableHead><TableHead>Account</TableHead><TableHead>Type</TableHead><TableHead className="text-right">Opening</TableHead><TableHead className="text-right">Debit</TableHead><TableHead className="text-right">Credit</TableHead><TableHead className="text-right">Closing (Dr +)</TableHead></TableRow></TableHeader>
          <TableBody>{rows.map((r) => <TableRow key={r.account_id}><TableCell className="text-muted-foreground">{r.code}</TableCell><TableCell className="font-medium">{r.name}</TableCell><TableCell className="text-muted-foreground">{r.type}</TableCell><TableCell className="num">{toNumber(r.opening) ? amount(r.opening) : ''}</TableCell><TableCell className="num">{amount(r.debit)}</TableCell><TableCell className="num">{amount(r.credit)}</TableCell><TableCell className={cn('num font-medium', toNumber(r.closing) < 0 && 'text-muted-foreground')}>{amount(r.closing)}</TableCell></TableRow>)}</TableBody>
          <TableFooter><TableRow><TableCell colSpan={3} className="text-right">Total</TableCell><TableCell className="num">{amount(sum(rows, (r) => r.opening))}</TableCell><TableCell className="num">{amount(sum(rows, (r) => r.debit))}</TableCell><TableCell className="num">{amount(sum(rows, (r) => r.credit))}</TableCell><TableCell className="num">{amount(diff)}</TableCell></TableRow></TableFooter>
        </Table>
      </Status>
    </div>
  );
}

export function PnlReport() {
  const orgId = useOrg();
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(toISODate());
  const q = useQuery({ queryKey: ['accounts', 'pnl', orgId, from, to], queryFn: () => profitAndLoss(orgId, from, to), enabled: Boolean(orgId && from && to) });
  const rows = q.data ?? [];
  const income = rows.filter((r) => r.section === 'income');
  const expense = rows.filter((r) => r.section === 'expense');
  const net = sum(income, (r) => r.amount) - sum(expense, (r) => r.amount);
  return (
    <div className="space-y-3">
      <Toolbar disabled={!rows.length} onExport={() => exportToExcel(`pnl-${from}-to-${to}`, [...rows.map((r) => ({ Section: r.section, Code: r.code, Account: r.name, Amount: toNumber(r.amount) })), { Section: 'net', Code: '', Account: 'Net profit', Amount: net }], 'P&L')}>
        <Field label="From" htmlFor="pl-from"><Input id="pl-from" type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label="To" htmlFor="pl-to"><Input id="pl-to" type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
        <Button size="sm" variant="ghost" className="mb-1" onClick={() => { setFrom(fyStart()); setTo(toISODate()); }}>This financial year</Button>
      </Toolbar>
      <PrintTitle title="Profit & loss" range={`${dateDMY(from)} to ${dateDMY(to)}`} />
      <Status isLoading={q.isLoading} error={q.error} empty={!rows.length}>
        <Table>
          <TableBody>
            <TableRow className="bg-muted/50 hover:bg-muted/50"><TableCell colSpan={2} className="font-semibold">Income</TableCell></TableRow>
            {income.map((r) => <TableRow key={r.code}><TableCell>{r.name} <span className="text-xs text-muted-foreground">{r.code}</span></TableCell><TableCell className="num w-40">{amount(r.amount)}</TableCell></TableRow>)}
            <TableRow className="font-medium"><TableCell className="text-right">Total income</TableCell><TableCell className="num">{amount(sum(income, (r) => r.amount))}</TableCell></TableRow>
            <TableRow className="bg-muted/50 hover:bg-muted/50"><TableCell colSpan={2} className="font-semibold">Expenses</TableCell></TableRow>
            {expense.map((r) => <TableRow key={r.code}><TableCell>{r.name} <span className="text-xs text-muted-foreground">{r.code}</span></TableCell><TableCell className="num">{amount(r.amount)}</TableCell></TableRow>)}
            <TableRow className="font-medium"><TableCell className="text-right">Total expenses</TableCell><TableCell className="num">{amount(sum(expense, (r) => r.amount))}</TableCell></TableRow>
          </TableBody>
          <TableFooter><TableRow><TableCell className="text-right">{net >= 0 ? 'Net profit' : 'Net loss'}</TableCell><TableCell className={cn('num text-base', net < 0 && 'text-destructive')}>{amount(Math.abs(net))}</TableCell></TableRow></TableFooter>
        </Table>
      </Status>
      <p className="text-xs text-muted-foreground">Purchases are expensed when bought and production moves no money, so this is a cash-basis trading result, not a stock-valued one.</p>
    </div>
  );
}

export function BalanceSheetReport() {
  const orgId = useOrg();
  const [asOn, setAsOn] = useState(toISODate());
  const q = useQuery({ queryKey: ['accounts', 'bs', orgId, asOn], queryFn: () => balanceSheet(orgId, asOn), enabled: Boolean(orgId && asOn) });
  const rows = q.data ?? [];
  const side = (s: string) => rows.filter((r) => r.section === s);
  const assets = sum(side('asset'), (r) => r.amount);
  const liab = sum(side('liability'), (r) => r.amount) + sum(side('equity'), (r) => r.amount);
  const Section = ({ title, key }: { title: string; key: string }) => (
    <>
      <TableRow className="bg-muted/50 hover:bg-muted/50"><TableCell colSpan={2} className="font-semibold">{title}</TableCell></TableRow>
      {side(key).map((r) => <TableRow key={r.code}><TableCell>{r.name}</TableCell><TableCell className="num w-40">{amount(r.amount)}</TableCell></TableRow>)}
    </>
  );
  return (
    <div className="space-y-3">
      <Toolbar disabled={!rows.length} onExport={() => exportToExcel(`balance-sheet-${asOn}`, rows.map((r) => ({ Section: r.section, Code: r.code, Account: r.name, Amount: toNumber(r.amount) })), 'Balance sheet')}>
        <Field label="As on" htmlFor="bs-date"><Input id="bs-date" type="date" className="h-8 w-40" value={asOn} onChange={(e) => setAsOn(e.target.value)} /></Field>
        <Badge variant={Math.abs(assets - liab) < 0.005 ? 'secondary' : 'destructive'} className="mb-1">{Math.abs(assets - liab) < 0.005 ? 'ties' : `off by ${amount(assets - liab)}`}</Badge>
      </Toolbar>
      <PrintTitle title="Balance sheet" range={`as on ${dateDMY(asOn)}`} />
      <Status isLoading={q.isLoading} error={q.error} empty={!rows.length}>
        <div className="grid md:grid-cols-2">
          <Table><TableBody><Section title="Assets" key="asset" /></TableBody><TableFooter><TableRow><TableCell className="text-right">Total assets</TableCell><TableCell className="num">{amount(assets)}</TableCell></TableRow></TableFooter></Table>
          <Table><TableBody><Section title="Liabilities" key="liability" /><Section title="Equity" key="equity" /></TableBody><TableFooter><TableRow><TableCell className="text-right">Total liabilities & equity</TableCell><TableCell className="num">{amount(liab)}</TableCell></TableRow></TableFooter></Table>
        </div>
      </Status>
      <p className="text-xs text-muted-foreground">Opening balances typed on customers, suppliers and accounts were never journalled; they appear as their own lines with "Opening balance equity" on the other side. Stock is not valued here.</p>
    </div>
  );
}

export function DayBookReport() {
  const orgId = useOrg();
  const [date, setDate] = useState(toISODate());
  const q = useQuery({ queryKey: ['accounts', 'daybook', orgId, date], queryFn: () => dayBook(orgId, date), enabled: Boolean(orgId && date) });
  const rows = q.data ?? [];
  const inflow = sum(rows.filter((r) => r.direction === 'in'), (r) => r.amount);
  const outflow = sum(rows.filter((r) => r.direction === 'out'), (r) => r.amount);
  return (
    <div className="space-y-3">
      <Toolbar disabled={!rows.length} onExport={() => exportToExcel(`day-book-${date}`, rows.map((r) => ({ Document: r.doc, 'No.': r.doc_no, Party: r.party, Narration: r.narration, Amount: toNumber(r.amount), Direction: r.direction, Entered: dateTimeDMY(r.at) })), 'Day book')}>
        <Field label="Date" htmlFor="db-date"><Input id="db-date" type="date" className="h-8 w-40" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
        <span className="mb-1 flex gap-2"><Badge variant="secondary">in {amount(inflow)}</Badge><Badge variant="outline">out {amount(outflow)}</Badge></span>
      </Toolbar>
      <PrintTitle title="Day book" range={dateDMY(date)} />
      <Status isLoading={q.isLoading} error={q.error} empty={!rows.length}>
        <Table>
          <TableHeader><TableRow><TableHead>Document</TableHead><TableHead>No.</TableHead><TableHead>Party</TableHead><TableHead>Narration</TableHead><TableHead className="text-right">In</TableHead><TableHead className="text-right">Out</TableHead><TableHead>Entered</TableHead></TableRow></TableHeader>
          <TableBody>{rows.map((r, i) => <TableRow key={`${r.doc}-${r.doc_id ?? i}`}><TableCell><Badge variant="outline">{r.doc}</Badge></TableCell><TableCell className="font-medium">{r.doc_no}</TableCell><TableCell>{r.party}</TableCell><TableCell className="text-muted-foreground">{r.narration}</TableCell><TableCell className="num">{r.direction === 'in' ? amount(r.amount) : r.direction === 'move' ? <span className="text-muted-foreground">{amount(r.amount)}</span> : ''}</TableCell><TableCell className="num">{r.direction === 'out' ? amount(r.amount) : ''}</TableCell><TableCell className="text-xs text-muted-foreground">{dateTimeDMY(r.at)}</TableCell></TableRow>)}</TableBody>
        </Table>
      </Status>
    </div>
  );
}

export function CashFlowReport() {
  const orgId = useOrg();
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(toISODate());
  const q = useQuery({ queryKey: ['accounts', 'cashflow', orgId, from, to], queryFn: () => cashFlow(orgId, from, to), enabled: Boolean(orgId && from && to) });
  const rows = q.data ?? [];
  const heads = rows.filter((r) => r.sort !== 0 && r.sort !== 99);
  const opening = rows.find((r) => r.sort === 0);
  const closing = rows.find((r) => r.sort === 99);
  return (
    <div className="space-y-3">
      <Toolbar disabled={!rows.length} onExport={() => exportToExcel(`cash-flow-${from}-to-${to}`, rows.map((r) => ({ Head: r.head, Inflow: toNumber(r.inflow), Outflow: toNumber(r.outflow) })), 'Cash flow')}>
        <Field label="From" htmlFor="cf-from"><Input id="cf-from" type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label="To" htmlFor="cf-to"><Input id="cf-to" type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
      </Toolbar>
      <PrintTitle title="Cash flow" range={`${dateDMY(from)} to ${dateDMY(to)}`} />
      <Status isLoading={q.isLoading} error={q.error} empty={!rows.length}>
        <Table>
          <TableHeader><TableRow><TableHead>Head</TableHead><TableHead className="text-right">Money in</TableHead><TableHead className="text-right">Money out</TableHead></TableRow></TableHeader>
          <TableBody>
            <TableRow className="bg-muted/40"><TableCell className="font-medium">Opening cash & bank</TableCell><TableCell className="num">{amount(opening?.inflow)}</TableCell><TableCell /></TableRow>
            {heads.map((r) => <TableRow key={r.head}><TableCell>{r.head}</TableCell><TableCell className="num">{toNumber(r.inflow) ? amount(r.inflow) : ''}</TableCell><TableCell className="num">{toNumber(r.outflow) ? amount(r.outflow) : ''}</TableCell></TableRow>)}
            <TableRow className="font-medium"><TableCell className="text-right">Period</TableCell><TableCell className="num">{amount(sum(heads, (r) => r.inflow))}</TableCell><TableCell className="num">{amount(sum(heads, (r) => r.outflow))}</TableCell></TableRow>
          </TableBody>
          <TableFooter><TableRow><TableCell>Closing cash & bank</TableCell><TableCell className="num">{amount(closing?.inflow)}</TableCell><TableCell className="num text-muted-foreground">net {amount(toNumber(closing?.inflow) - toNumber(opening?.inflow))}</TableCell></TableRow></TableFooter>
        </Table>
      </Status>
      <p className="text-xs text-muted-foreground">Transfers between your own accounts appear on both sides and net to zero.</p>
    </div>
  );
}

export function ItemProfitReport() {
  const orgId = useOrg();
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(toISODate());
  const [group, setGroup] = useState<'item' | 'section'>('item');
  const q = useQuery({ queryKey: ['accounts', 'item-profit', orgId, from, to, group], queryFn: () => itemProfit(orgId, from, to, group), enabled: Boolean(orgId && from && to) });
  const rows = q.data ?? [];
  const sale = sum(rows, (r) => r.sale_value);
  const cost = sum(rows, (r) => r.cost_value);
  return (
    <div className="space-y-3">
      <Toolbar disabled={!rows.length} onExport={() => exportToExcel(`item-profit-${group}-${from}-to-${to}`, rows.map((r) => ({ [group === 'item' ? 'Item' : 'Section']: r.group_label, Boxes: toNumber(r.boxes), Qty: toNumber(r.qty), 'Sale value': toNumber(r.sale_value), Cost: toNumber(r.cost_value), 'Gross profit': toNumber(r.gross_profit), 'Margin %': toNumber(r.margin_pct) })), 'Item profit')}>
        <Field label="From" htmlFor="ip-from"><Input id="ip-from" type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label="To" htmlFor="ip-to"><Input id="ip-to" type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
        <Field label="By" htmlFor="ip-group"><NativeSelect id="ip-group" className="h-8 w-32" value={group} onChange={(e) => setGroup(e.target.value as 'item' | 'section')}><option value="item">Item</option><option value="section">Section</option></NativeSelect></Field>
      </Toolbar>
      <PrintTitle title={`Item profitability by ${group}`} range={`${dateDMY(from)} to ${dateDMY(to)}`} />
      <Status isLoading={q.isLoading} error={q.error} empty={!rows.length}>
        <Table>
          <TableHeader><TableRow><TableHead>{group === 'item' ? 'Item' : 'Section'}</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead className="text-right">Qty</TableHead><TableHead className="text-right">Sale value</TableHead><TableHead className="text-right">Cost</TableHead><TableHead className="text-right">Gross profit</TableHead><TableHead className="text-right">Margin</TableHead></TableRow></TableHeader>
          <TableBody>{rows.map((r) => <TableRow key={r.group_key}><TableCell className="font-medium">{r.group_label}</TableCell><TableCell className="num">{qty(r.boxes)}</TableCell><TableCell className="num text-muted-foreground">{qty(r.qty)}</TableCell><TableCell className="num">{amount(r.sale_value)}</TableCell><TableCell className="num">{amount(r.cost_value)}</TableCell><TableCell className={cn('num font-medium', toNumber(r.gross_profit) < 0 && 'text-destructive')}>{amount(r.gross_profit)}</TableCell><TableCell className="num text-muted-foreground">{r.margin_pct !== null && r.margin_pct !== undefined ? `${qty(r.margin_pct, 1)}%` : ''}</TableCell></TableRow>)}</TableBody>
          <TableFooter><TableRow><TableCell className="text-right">Total</TableCell><TableCell className="num">{qty(sum(rows, (r) => r.boxes))}</TableCell><TableCell className="num">{qty(sum(rows, (r) => r.qty))}</TableCell><TableCell className="num">{amount(sale)}</TableCell><TableCell className="num">{amount(cost)}</TableCell><TableCell className="num">{amount(sale - cost)}</TableCell><TableCell className="num">{sale ? `${qty(((sale - cost) / sale) * 100, 1)}%` : ''}</TableCell></TableRow></TableFooter>
        </Table>
      </Status>
      <p className="text-xs text-muted-foreground">Cost per unit is the latest closed production batch (ingredients + labour ÷ units made) for made items, else the purchase rate on Add Product. {int(rows.length)} rows.</p>
    </div>
  );
}

export { Fragment };
