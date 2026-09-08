import { useQuery } from '@tanstack/react-query';
import { Download, Printer } from 'lucide-react';
import { Fragment, useMemo, useState } from 'react';
import { Link, NavLink, useSearchParams } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe } from '@/features/auth/hooks';
import { getCustomer, searchCustomers, type CustomerRow } from '@/features/customers/api';
import { listStaff, receiptModesApi, routesApi } from '@/features/setup/api';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, int, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import {
  collectionByMode, customerLedger, incentiveStatement, outstandingAgeing, receiptsRegister, routeCollection, routeProfitability, salesSummary,
  type LedgerRow, type RegisterRow, type SalesGroup,
} from '../api';

const TABS = [
  { key: 'register', label: 'Receipts register' },
  { key: 'ledger', label: 'Customer ledger' },
  { key: 'ageing', label: 'Outstanding ageing' },
  { key: 'modes', label: 'Collection by mode' },
  { key: 'routes', label: 'Route-wise' },
  { key: 'sales', label: 'Sales' },
  { key: 'profit', label: 'Route profit' },
  { key: 'incentives', label: 'Incentives' },
] as const;
export type ReportTab = (typeof TABS)[number]['key'];

/** First of the current month — the client's registers are monthly by habit. */
function monthStart(): string {
  const d = new Date();
  return toISODate(new Date(d.getFullYear(), d.getMonth(), 1));
}

export function ReportsPage({ tab = 'register' }: { tab?: ReportTab }) {
  return (
    <div className="space-y-3">
      <PageHeader title="Reports" description="Every figure is a SUM over the same tables the screens write. Nothing here is stored separately." />
      <nav className="no-print flex flex-wrap gap-1 border-b" aria-label="Reports">
        {TABS.map((t) => (
          <NavLink key={t.key} to={t.key === 'register' ? '/reports' : `/reports/${t.key}`} end className={({ isActive }) => cn('-mb-px border-b-2 px-3 py-1.5 text-sm', isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}>
            {t.label}
          </NavLink>
        ))}
      </nav>
      {tab === 'register' && <RegisterReport />}
      {tab === 'ledger' && <LedgerReport />}
      {tab === 'ageing' && <AgeingReport />}
      {tab === 'modes' && <ModesReport />}
      {tab === 'routes' && <RoutesReport />}
      {tab === 'sales' && <SalesReport />}
      {tab === 'profit' && <RouteProfitReport />}
      {tab === 'incentives' && <IncentivesReport />}
    </div>
  );
}

// ---------------------------------------------------------------- shared bits
function DateRange({ from, to, setFrom, setTo, prefix }: { from: string; to: string; setFrom: (v: string) => void; setTo: (v: string) => void; prefix: string }) {
  return (
    <>
      <Field label="From" htmlFor={`${prefix}-from`}><Input id={`${prefix}-from`} type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
      <Field label="To" htmlFor={`${prefix}-to`}><Input id={`${prefix}-to`} type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
    </>
  );
}

function RouteFilter({ value, onChange, id }: { value: string; onChange: (v: string) => void; id: string }) {
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list });
  return (
    <Field label="Route" htmlFor={id}>
      <NativeSelect id={id} className="h-8 w-48" value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="">All routes</option>
        {(routes.data ?? []).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
      </NativeSelect>
    </Field>
  );
}

function Actions({ onExport, disabled, children }: { onExport: () => void; disabled: boolean; children?: React.ReactNode }) {
  return (
    <span className="no-print ml-auto flex items-center gap-2 pb-1">
      {children}
      <Button variant="outline" size="sm" onClick={() => window.print()} disabled={disabled}><Printer /> Print</Button>
      <Button variant="outline" size="sm" onClick={onExport} disabled={disabled}><Download /> Excel</Button>
    </span>
  );
}

function Status({ isLoading, error, empty, emptyText, children }: { isLoading: boolean; error: Error | null; empty: boolean; emptyText: string; children: React.ReactNode }) {
  if (isLoading) return <Spinner />;
  if (error) return <p role="alert" className="text-sm text-destructive">Could not load the report: {error.message}</p>;
  if (empty) return <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">{emptyText}</p>;
  return <div className="overflow-x-auto rounded-md border">{children}</div>;
}

function PrintTitle({ title, range }: { title: string; range: string }) {
  const me = useMe();
  return (
    <div className="hidden print:block">
      <h2 className="text-lg font-semibold">{me.data?.org_name}</h2>
      <p className="text-sm">{title} · {range}</p>
    </div>
  );
}

const sumBy = <T,>(rows: T[], f: (r: T) => number | string | null | undefined) => rows.reduce((s, r) => s + toNumber(f(r)), 0);

// ---------------------------------------------------------------- 1. register
/**
 * The client's receipts & payments register, in their exact column order:
 * S.No · Name · Town · Total Outstanding · <one column per active receipt mode> ·
 * Fresh Return · Rate Difference · Return · Remaining Outstanding.
 */
function RegisterReport() {
  const me = useMe();
  const orgId = me.data?.org_id ?? '';
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(toISODate());
  const [routeId, setRouteId] = useState('');
  const modes = useQuery({ queryKey: ['setup', 'receipt_modes'], queryFn: receiptModesApi.list });
  const report = useQuery({ queryKey: ['reports', 'register', orgId, from, to, routeId], queryFn: () => receiptsRegister(orgId, from, to, routeId), enabled: Boolean(orgId && from && to) });

  const rows = useMemo(() => report.data ?? [], [report.data]);
  // Active modes in Setup order, plus any inactive mode that still has money in this period.
  const modeCols = useMemo(() => {
    const active = (modes.data ?? []).filter((m) => m.is_active).map((m) => m.code);
    const seen = new Set(active);
    for (const r of rows) for (const k of Object.keys(byMode(r))) if (!seen.has(k)) { seen.add(k); active.push(k); }
    return active;
  }, [modes.data, rows]);

  const toRow = (r: RegisterRow) => {
    const bm = byMode(r);
    const o: Record<string, unknown> = { 'S.No': toNumber(r.sno), Name: r.name, Town: r.town ?? '', 'Total Outstanding': toNumber(r.total_outstanding) };
    for (const c of modeCols) o[c] = toNumber(bm[c]);
    o['Fresh Return'] = toNumber(r.fresh_return);
    o['Rate Difference'] = toNumber(r.rate_difference);
    o['Return'] = toNumber(r.damage_return);
    o['Remaining Outstanding'] = toNumber(r.remaining_outstanding);
    return o;
  };
  const onExport = () => exportToExcel(`receipts-register-${from}-to-${to}`, rows.map(toRow), 'Register');

  return (
    <div className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} prefix="rg" />
        <RouteFilter id="rg-route" value={routeId} onChange={setRouteId} />
        <Actions onExport={onExport} disabled={!rows.length} />
      </div>
      <PrintTitle title="Receipts & payments register" range={`${dateDMY(from)} to ${dateDMY(to)}`} />
      <Status isLoading={report.isLoading || modes.isLoading} error={report.error} empty={!rows.length} emptyText="No collections, returns or balances in this period.">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-12">S.No</TableHead><TableHead>Name</TableHead><TableHead>Town</TableHead>
              <TableHead className="text-right">Total Outstanding</TableHead>
              {modeCols.map((c) => <TableHead key={c} className="text-right">{c}</TableHead>)}
              <TableHead className="text-right">Fresh Return</TableHead><TableHead className="text-right">Rate Difference</TableHead><TableHead className="text-right">Return</TableHead>
              <TableHead className="text-right">Remaining Outstanding</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => {
              const bm = byMode(r);
              return (
                <TableRow key={r.customer_id ?? String(r.sno)}>
                  <TableCell className="text-muted-foreground">{int(r.sno)}</TableCell>
                  <TableCell className="font-medium"><Link to={`/reports/ledger?customer=${r.customer_id}`} className="hover:underline">{r.name}</Link></TableCell>
                  <TableCell>{r.town}</TableCell>
                  <TableCell className="num">{amount(r.total_outstanding)}</TableCell>
                  {modeCols.map((c) => <TableCell key={c} className="num">{toNumber(bm[c]) ? amount(bm[c]) : ''}</TableCell>)}
                  <TableCell className="num">{toNumber(r.fresh_return) ? amount(r.fresh_return) : ''}</TableCell>
                  <TableCell className="num">{toNumber(r.rate_difference) ? amount(r.rate_difference) : ''}</TableCell>
                  <TableCell className="num">{toNumber(r.damage_return) ? amount(r.damage_return) : ''}</TableCell>
                  <TableCell className={cn('num font-medium', toNumber(r.remaining_outstanding) < 0 && 'text-destructive')}>{amount(r.remaining_outstanding)}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell colSpan={3} className="text-right">Total</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.total_outstanding))}</TableCell>
              {modeCols.map((c) => <TableCell key={c} className="num">{amount(sumBy(rows, (r) => byMode(r)[c]))}</TableCell>)}
              <TableCell className="num">{amount(sumBy(rows, (r) => r.fresh_return))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.rate_difference))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.damage_return))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.remaining_outstanding))}</TableCell>
            </TableRow>
          </TableFooter>
        </Table>
      </Status>
    </div>
  );
}

function byMode(r: RegisterRow): Record<string, number | string | null> {
  const v = r.by_mode;
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, number | string | null>) : {};
}

// ---------------------------------------------------------------- 2. ledger
function LedgerReport() {
  // Other reports deep-link here with ?customer=<id>; the picker is prefilled from it.
  const [params] = useSearchParams();
  const preset = params.get('customer') ?? '';
  const [picked, setPicked] = useState<CustomerRow | null>(null);
  const presetCustomer = useQuery({ queryKey: ['customers', 'one', preset], queryFn: () => getCustomer(preset), enabled: Boolean(preset) && !picked });
  const customer = picked ?? presetCustomer.data ?? null;
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const customerId = customer?.id ?? '';
  const ledger = useQuery({ queryKey: ['reports', 'ledger', customerId, from, to], queryFn: () => customerLedger(customerId, from, to), enabled: Boolean(customerId) });
  const rows = ledger.data ?? [];
  const closing = rows.length ? toNumber(rows[rows.length - 1]?.balance) : 0;

  const onExport = () => exportToExcel(`ledger-${customer?.name ?? customerId}`, rows.map((l) => ({ Date: l.entry_date ? dateDMY(l.entry_date) : '', Document: l.doc, 'No.': l.doc_no ?? '', Particulars: l.particulars ?? '', Debit: toNumber(l.debit), Credit: toNumber(l.credit), Balance: toNumber(l.balance) })), 'Ledger');
  const link = (l: LedgerRow) => {
    if (!l.doc_id) return null;
    if (l.doc === 'Invoice') return `/invoices/${l.doc_id}`;
    if (l.doc === 'Receipt') return `/receipts/${l.doc_id}`;
    return `/returns/${l.doc_id}`;
  };

  return (
    <div className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <Field label="Customer" htmlFor="lg-cust" className="w-80">
          <Combobox<CustomerRow> id="lg-cust" value={customer} onChange={setPicked} search={searchCustomers} queryKey="customers-pick" getKey={(c) => c.id ?? ''} getLabel={(c) => `${c.name}${c.town ? ` — ${c.town}` : ''}`} renderOption={(c) => <span><span className="font-medium">{c.name}</span> <span className="text-muted-foreground">{c.town} · {c.mobile1}</span></span>} placeholder="Name, mobile or town…" autoFocus eager />
        </Field>
        <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} prefix="lg" />
        <Actions onExport={onExport} disabled={!rows.length}>
          {rows.length > 0 && <Badge variant={closing > 0 ? 'default' : 'secondary'}>Balance {amount(closing)}</Badge>}
        </Actions>
      </div>
      <PrintTitle title={`Ledger — ${customer?.name ?? ''}`} range={from || to ? `${from ? dateDMY(from) : 'start'} to ${to ? dateDMY(to) : 'today'}` : 'all dates'} />
      {!customerId ? <p className="text-sm text-muted-foreground">Pick a customer. Opening balance, every bill, receipt and return, with the running balance.</p> : (
        <Status isLoading={ledger.isLoading} error={ledger.error} empty={!rows.length} emptyText="No entries.">
          <Table>
            <TableHeader><TableRow><TableHead className="w-28">Date</TableHead><TableHead className="w-32">Document</TableHead><TableHead className="w-28">No.</TableHead><TableHead>Particulars</TableHead><TableHead className="text-right">Debit</TableHead><TableHead className="text-right">Credit</TableHead><TableHead className="text-right">Balance</TableHead></TableRow></TableHeader>
            <TableBody>
              {rows.map((l, i) => {
                const to = link(l);
                return (
                  <TableRow key={`${l.doc}-${l.doc_id ?? i}`} className={cn(l.doc === 'Opening' && 'bg-muted/40')}>
                    <TableCell>{l.entry_date ? dateDMY(l.entry_date) : ''}</TableCell>
                    <TableCell>{l.doc}</TableCell>
                    <TableCell className="font-medium">{to ? <Link to={to} className="hover:underline">{l.doc_no}</Link> : l.doc_no}</TableCell>
                    <TableCell className="text-muted-foreground">{l.particulars}</TableCell>
                    <TableCell className="num">{toNumber(l.debit) ? amount(l.debit) : ''}</TableCell>
                    <TableCell className="num">{toNumber(l.credit) ? amount(l.credit) : ''}</TableCell>
                    <TableCell className={cn('num font-medium', toNumber(l.balance) < 0 && 'text-destructive')}>{amount(l.balance)}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell colSpan={4} className="text-right">Total</TableCell>
                <TableCell className="num">{amount(sumBy(rows, (l) => l.debit))}</TableCell>
                <TableCell className="num">{amount(sumBy(rows, (l) => l.credit))}</TableCell>
                <TableCell className="num">{amount(closing)}</TableCell>
              </TableRow>
            </TableFooter>
          </Table>
        </Status>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- 3. ageing
function AgeingReport() {
  const me = useMe();
  const orgId = me.data?.org_id ?? '';
  const [asOn, setAsOn] = useState(toISODate());
  const [routeId, setRouteId] = useState('');
  const report = useQuery({ queryKey: ['reports', 'ageing', orgId, asOn, routeId], queryFn: () => outstandingAgeing(orgId, asOn, routeId), enabled: Boolean(orgId && asOn) });
  const rows = report.data ?? [];
  const onExport = () => exportToExcel(`ageing-${asOn}`, rows.map((r) => ({ Name: r.name, Town: r.town ?? '', Route: r.route_name ?? '', Mobile: r.mobile1 ?? '', '0-15 days': toNumber(r.b0_15), '16-30 days': toNumber(r.b16_30), '31-60 days': toNumber(r.b31_60), '60+ days': toNumber(r.b60p), 'On account': toNumber(r.on_account), Outstanding: toNumber(r.outstanding), 'Oldest (days)': toNumber(r.oldest_days) })), 'Ageing');

  return (
    <div className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <Field label="As on" htmlFor="ag-date"><Input id="ag-date" type="date" className="h-8 w-40" value={asOn} onChange={(e) => setAsOn(e.target.value)} /></Field>
        <RouteFilter id="ag-route" value={routeId} onChange={setRouteId} />
        <Actions onExport={onExport} disabled={!rows.length} />
      </div>
      <PrintTitle title="Outstanding ageing" range={`as on ${dateDMY(asOn)}`} />
      <p className="text-xs text-muted-foreground">Buckets are by bill date after FIFO allocation of receipts. "On account" is money received but not yet allocated to a bill; it is already netted in Outstanding.</p>
      <Status isLoading={report.isLoading} error={report.error} empty={!rows.length} emptyText="Nothing outstanding.">
        <Table>
          <TableHeader><TableRow><TableHead>Name</TableHead><TableHead>Town</TableHead><TableHead>Route</TableHead><TableHead className="text-right">0–15</TableHead><TableHead className="text-right">16–30</TableHead><TableHead className="text-right">31–60</TableHead><TableHead className="text-right">60+</TableHead><TableHead className="text-right">On account</TableHead><TableHead className="text-right">Outstanding</TableHead><TableHead className="text-right">Oldest</TableHead></TableRow></TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.customer_id ?? r.name} className={cn(toNumber(r.b60p) > 0 && 'bg-red-50/60')}>
                <TableCell className="font-medium"><Link to={`/reports/ledger?customer=${r.customer_id}`} className="hover:underline">{r.name}</Link></TableCell>
                <TableCell>{r.town}</TableCell>
                <TableCell className="text-muted-foreground">{r.route_name}</TableCell>
                <TableCell className="num">{toNumber(r.b0_15) ? amount(r.b0_15) : ''}</TableCell>
                <TableCell className="num">{toNumber(r.b16_30) ? amount(r.b16_30) : ''}</TableCell>
                <TableCell className="num">{toNumber(r.b31_60) ? amount(r.b31_60) : ''}</TableCell>
                <TableCell className={cn('num', toNumber(r.b60p) > 0 && 'font-medium text-destructive')}>{toNumber(r.b60p) ? amount(r.b60p) : ''}</TableCell>
                <TableCell className="num text-muted-foreground">{toNumber(r.on_account) ? amount(r.on_account) : ''}</TableCell>
                <TableCell className="num font-medium">{amount(r.outstanding)}</TableCell>
                <TableCell className="num text-muted-foreground">{r.oldest_days ? `${int(r.oldest_days)} d` : ''}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell colSpan={3} className="text-right">Total</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.b0_15))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.b16_30))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.b31_60))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.b60p))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.on_account))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.outstanding))}</TableCell>
              <TableCell />
            </TableRow>
          </TableFooter>
        </Table>
      </Status>
    </div>
  );
}

// ---------------------------------------------------------------- 4. by mode
function ModesReport() {
  const me = useMe();
  const orgId = me.data?.org_id ?? '';
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(toISODate());
  const [routeId, setRouteId] = useState('');
  const report = useQuery({ queryKey: ['reports', 'modes', orgId, from, to, routeId], queryFn: () => collectionByMode(orgId, from, to, routeId), enabled: Boolean(orgId && from && to) });
  const rows = report.data ?? [];
  const collection = rows.filter((r) => r.is_collection);
  const other = rows.filter((r) => !r.is_collection);
  const onExport = () => exportToExcel(`collection-by-mode-${from}-to-${to}`, rows.map((r) => ({ Mode: r.code, Name: r.name, 'Counts as collection': r.is_collection ? 'Yes' : 'No', Receipts: toNumber(r.receipts), Amount: toNumber(r.amount) })), 'By mode');

  return (
    <div className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} prefix="md" />
        <RouteFilter id="md-route" value={routeId} onChange={setRouteId} />
        <Actions onExport={onExport} disabled={!rows.length} />
      </div>
      <PrintTitle title="Collection by mode" range={`${dateDMY(from)} to ${dateDMY(to)}`} />
      <Status isLoading={report.isLoading} error={report.error} empty={!rows.length} emptyText="No receipt modes set up.">
        <Table>
          <TableHeader><TableRow><TableHead className="w-24">Mode</TableHead><TableHead>Name</TableHead><TableHead className="text-right">Receipts</TableHead><TableHead className="text-right">Amount</TableHead><TableHead className="text-right">Share</TableHead></TableRow></TableHeader>
          <TableBody>
            {[...collection, ...other].map((r) => {
              const total = sumBy(r.is_collection ? collection : other, (x) => x.amount);
              return (
                <TableRow key={r.mode_id ?? r.code} className={cn(!r.is_collection && 'text-muted-foreground')}>
                  <TableCell className="font-medium">{r.code}</TableCell>
                  <TableCell>{r.name}{!r.is_collection && <span className="ml-2 text-xs">(adjustment, not cash)</span>}</TableCell>
                  <TableCell className="num">{int(r.receipts)}</TableCell>
                  <TableCell className="num">{amount(r.amount)}</TableCell>
                  <TableCell className="num">{total ? `${qty((toNumber(r.amount) / total) * 100, 1)}%` : ''}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
          <TableFooter>
            <TableRow><TableCell colSpan={3} className="text-right">Collected (cash, bank…)</TableCell><TableCell className="num">{amount(sumBy(collection, (r) => r.amount))}</TableCell><TableCell /></TableRow>
            <TableRow><TableCell colSpan={3} className="text-right">Adjustments (breakage…)</TableCell><TableCell className="num">{amount(sumBy(other, (r) => r.amount))}</TableCell><TableCell /></TableRow>
          </TableFooter>
        </Table>
      </Status>
    </div>
  );
}

// ---------------------------------------------------------------- 5. routes
function RoutesReport() {
  const me = useMe();
  const orgId = me.data?.org_id ?? '';
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(toISODate());
  const report = useQuery({ queryKey: ['reports', 'routes', orgId, from, to], queryFn: () => routeCollection(orgId, from, to), enabled: Boolean(orgId && from && to) });
  const rows = report.data ?? [];
  const onExport = () => exportToExcel(`route-wise-${from}-to-${to}`, rows.map((r) => ({ Route: r.route_name, Customers: toNumber(r.customers), Invoices: toNumber(r.invoices), Sales: toNumber(r.sales), Collected: toNumber(r.collected), Returns: toNumber(r.returned), 'Outstanding (live)': toNumber(r.outstanding) })), 'Route-wise');

  return (
    <div className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} prefix="rt" />
        <Actions onExport={onExport} disabled={!rows.length} />
      </div>
      <PrintTitle title="Route-wise sales & collection" range={`${dateDMY(from)} to ${dateDMY(to)}`} />
      <Status isLoading={report.isLoading} error={report.error} empty={!rows.length} emptyText="No customers yet.">
        <Table>
          <TableHeader><TableRow><TableHead>Route</TableHead><TableHead className="text-right">Customers</TableHead><TableHead className="text-right">Invoices</TableHead><TableHead className="text-right">Sales</TableHead><TableHead className="text-right">Collected</TableHead><TableHead className="text-right">Returns</TableHead><TableHead className="text-right">Collection %</TableHead><TableHead className="text-right">Outstanding (live)</TableHead></TableRow></TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.route_id ?? 'none'}>
                <TableCell className="font-medium">{r.route_name}</TableCell>
                <TableCell className="num">{int(r.customers)}</TableCell>
                <TableCell className="num">{int(r.invoices)}</TableCell>
                <TableCell className="num">{amount(r.sales)}</TableCell>
                <TableCell className="num">{amount(r.collected)}</TableCell>
                <TableCell className="num">{toNumber(r.returned) ? amount(r.returned) : ''}</TableCell>
                <TableCell className="num text-muted-foreground">{toNumber(r.sales) ? `${qty((toNumber(r.collected) / toNumber(r.sales)) * 100, 1)}%` : ''}</TableCell>
                <TableCell className={cn('num font-medium', toNumber(r.outstanding) < 0 && 'text-destructive')}>{amount(r.outstanding)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell className="text-right">Total</TableCell>
              <TableCell className="num">{int(sumBy(rows, (r) => r.customers))}</TableCell>
              <TableCell className="num">{int(sumBy(rows, (r) => r.invoices))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.sales))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.collected))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.returned))}</TableCell>
              <TableCell />
              <TableCell className="num">{amount(sumBy(rows, (r) => r.outstanding))}</TableCell>
            </TableRow>
          </TableFooter>
        </Table>
      </Status>
    </div>
  );
}

// ---------------------------------------------------------------- 6. sales
const SALES_GROUPS: { key: SalesGroup; label: string; col: string }[] = [
  { key: 'day', label: 'Daily', col: 'Date' },
  { key: 'month', label: 'Monthly', col: 'Month' },
  { key: 'customer', label: 'Customer-wise', col: 'Customer' },
  { key: 'town', label: 'Town-wise', col: 'Town' },
  { key: 'route', label: 'Route-wise', col: 'Route' },
  { key: 'item', label: 'Item-wise', col: 'Item' },
  { key: 'section', label: 'Section-wise', col: 'Section' },
];

function SalesReport() {
  const me = useMe();
  const orgId = me.data?.org_id ?? '';
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(toISODate());
  const [group, setGroup] = useState<SalesGroup>('day');
  const report = useQuery({ queryKey: ['reports', 'sales', orgId, from, to, group], queryFn: () => salesSummary(orgId, from, to, group), enabled: Boolean(orgId && from && to) });
  const rows = report.data ?? [];
  const g = SALES_GROUPS.find((x) => x.key === group) ?? SALES_GROUPS[0]!;
  const lineLevel = group === 'item' || group === 'section';
  const total = sumBy(rows, (r) => r.amount);
  const onExport = () => exportToExcel(`sales-${group}-${from}-to-${to}`, rows.map((r) => ({ [g.col]: r.group_label, Invoices: toNumber(r.invoices), Boxes: toNumber(r.boxes), Qty: toNumber(r.qty), Amount: toNumber(r.amount) })), `Sales ${g.label}`);

  return (
    <div className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} prefix="sl" />
        <Field label="Group by" htmlFor="sl-group">
          <NativeSelect id="sl-group" className="h-8 w-44" value={group} onChange={(e) => setGroup(e.target.value as SalesGroup)}>
            {SALES_GROUPS.map((x) => <option key={x.key} value={x.key}>{x.label}</option>)}
          </NativeSelect>
        </Field>
        <Actions onExport={onExport} disabled={!rows.length}>
          {rows.length > 0 && <Badge variant="secondary">Total {amount(total)}</Badge>}
        </Actions>
      </div>
      <PrintTitle title={`Sales — ${g.label}`} range={`${dateDMY(from)} to ${dateDMY(to)}`} />
      <Status isLoading={report.isLoading} error={report.error} empty={!rows.length} emptyText="No confirmed invoices in this period. Draft and cancelled bills are not counted.">
        <Table>
          <TableHeader><TableRow><TableHead>{g.col}</TableHead><TableHead className="text-right">Invoices</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead className="text-right">Qty</TableHead><TableHead className="text-right">Amount</TableHead><TableHead className="text-right">Share</TableHead></TableRow></TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.group_key ?? r.group_label}>
                <TableCell className="font-medium">{group === 'customer' && r.group_key ? <Link to={`/reports/ledger?customer=${r.group_key}`} className="hover:underline">{r.group_label}</Link> : r.group_label}</TableCell>
                <TableCell className="num">{int(r.invoices)}</TableCell>
                <TableCell className="num">{qty(r.boxes)}</TableCell>
                <TableCell className="num text-muted-foreground">{qty(r.qty)}</TableCell>
                <TableCell className="num">{amount(r.amount)}</TableCell>
                <TableCell className="num text-muted-foreground">{total ? `${qty((toNumber(r.amount) / total) * 100, 1)}%` : ''}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell className="text-right">Total</TableCell>
              <TableCell className="num">{lineLevel ? '' : int(sumBy(rows, (r) => r.invoices))}</TableCell>
              <TableCell className="num">{qty(sumBy(rows, (r) => r.boxes))}</TableCell>
              <TableCell className="num">{qty(sumBy(rows, (r) => r.qty))}</TableCell>
              <TableCell className="num">{amount(total)}</TableCell>
              <TableCell />
            </TableRow>
          </TableFooter>
        </Table>
      </Status>
      {lineLevel && <p className="text-xs text-muted-foreground">Line-level amounts before invoice-level rounding or discount; the total can differ from the invoice total by those adjustments.</p>}
    </div>
  );
}

// ---------------------------------------------------------------- 7. route profit
/**
 * What each route earns after the goods, the trip and the driver are paid for. A
 * sale belongs to the van's route when sold on a trip, else to the customer's route.
 */
function RouteProfitReport() {
  const me = useMe();
  const orgId = me.data?.org_id ?? '';
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(toISODate());
  const report = useQuery({ queryKey: ['reports', 'profit', orgId, from, to], queryFn: () => routeProfitability(orgId, from, to), enabled: Boolean(orgId && from && to) });
  const rows = report.data ?? [];
  const onExport = () => exportToExcel(`route-profit-${from}-to-${to}`, rows.map((r) => ({ Route: r.route_name, Customers: toNumber(r.customers), Trips: toNumber(r.trips), Km: toNumber(r.km), Invoices: toNumber(r.invoices), Boxes: toNumber(r.boxes), Sales: toNumber(r.sales), Returns: toNumber(r.returns), 'Cost of goods': toNumber(r.cogs), 'Gross margin': toNumber(r.gross_margin), 'Trip expenses': toNumber(r.trip_expenses), 'Driver wages': toNumber(r.driver_wages), 'Net profit': toNumber(r.net_profit), 'Margin %': toNumber(r.margin_pct), Collection: toNumber(r.collection), 'Sales per km': toNumber(r.sales_per_km) })), 'Route profit');
  const net = sumBy(rows, (r) => r.net_profit);
  return (
    <div className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <DateRange from={from} to={to} setFrom={setFrom} setTo={setTo} prefix="rp" />
        <Actions onExport={onExport} disabled={!rows.length}>
          {rows.length > 0 && <Badge variant={net < 0 ? 'destructive' : 'secondary'}>Net {amount(net)}</Badge>}
        </Actions>
      </div>
      <PrintTitle title="Route profitability" range={`${dateDMY(from)} to ${dateDMY(to)}`} />
      <Status isLoading={report.isLoading} error={report.error} empty={!rows.length} emptyText="No sales or trips in this period.">
        <Table>
          <TableHeader><TableRow><TableHead>Route</TableHead><TableHead className="text-right">Trips</TableHead><TableHead className="text-right">Km</TableHead><TableHead className="text-right">Bills</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead className="text-right">Sales</TableHead><TableHead className="text-right">Returns</TableHead><TableHead className="text-right">Cost of goods</TableHead><TableHead className="text-right">Gross</TableHead><TableHead className="text-right">Trip exp.</TableHead><TableHead className="text-right">Wages</TableHead><TableHead className="text-right">Net</TableHead><TableHead className="text-right">Margin</TableHead><TableHead className="text-right">Collected</TableHead><TableHead className="text-right">₹ / km</TableHead></TableRow></TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.route_id ?? 'none'}>
                <TableCell className="font-medium">{r.route_name}<div className="text-xs text-muted-foreground">{int(r.customers)} customers</div></TableCell>
                <TableCell className="num">{int(r.trips)}</TableCell>
                <TableCell className="num">{toNumber(r.km) ? qty(r.km, 1) : ''}</TableCell>
                <TableCell className="num">{int(r.invoices)}</TableCell>
                <TableCell className="num">{qty(r.boxes)}</TableCell>
                <TableCell className="num">{amount(r.sales)}</TableCell>
                <TableCell className="num">{toNumber(r.returns) ? amount(r.returns) : ''}</TableCell>
                <TableCell className="num text-muted-foreground">{amount(r.cogs)}</TableCell>
                <TableCell className="num">{amount(r.gross_margin)}</TableCell>
                <TableCell className="num">{toNumber(r.trip_expenses) ? amount(r.trip_expenses) : ''}</TableCell>
                <TableCell className="num">{toNumber(r.driver_wages) ? amount(r.driver_wages) : ''}</TableCell>
                <TableCell className={cn('num font-medium', toNumber(r.net_profit) < 0 && 'text-destructive')}>{amount(r.net_profit)}</TableCell>
                <TableCell className="num text-muted-foreground">{r.margin_pct === null ? '' : `${qty(r.margin_pct, 1)}%`}</TableCell>
                <TableCell className="num">{amount(r.collection)}</TableCell>
                <TableCell className="num text-muted-foreground">{r.sales_per_km === null ? '' : amount(r.sales_per_km)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell className="text-right">Total</TableCell>
              <TableCell className="num">{int(sumBy(rows, (r) => r.trips))}</TableCell>
              <TableCell className="num">{qty(sumBy(rows, (r) => r.km), 1)}</TableCell>
              <TableCell className="num">{int(sumBy(rows, (r) => r.invoices))}</TableCell>
              <TableCell className="num">{qty(sumBy(rows, (r) => r.boxes))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.sales))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.returns))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.cogs))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.gross_margin))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.trip_expenses))}</TableCell>
              <TableCell className="num">{amount(sumBy(rows, (r) => r.driver_wages))}</TableCell>
              <TableCell className={cn('num', net < 0 && 'text-destructive')}>{amount(net)}</TableCell>
              <TableCell />
              <TableCell className="num">{amount(sumBy(rows, (r) => r.collection))}</TableCell>
              <TableCell />
            </TableRow>
          </TableFooter>
        </Table>
      </Status>
      <p className="text-xs text-muted-foreground">Cost of goods uses the latest closed batch cost per unit (else the purchase rate), as on the Item profit report. Trip expenses and km come from settled trips; wages are the driver's daily wage per trip.</p>
    </div>
  );
}

// ---------------------------------------------------------------- 8. incentives
const BASIS_LABEL: Record<string, string> = { sales_pct: '% of net sales', collection_pct: '% of collection', per_box: '₹ per box', per_new_customer: '₹ per new shop', slab: 'slab on net sales' };

function IncentivesReport() {
  const me = useMe();
  const orgId = me.data?.org_id ?? '';
  const [month, setMonth] = useState(toISODate().slice(0, 7));
  const [staffId, setStaffId] = useState('');
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const report = useQuery({ queryKey: ['reports', 'incentives', orgId, month, staffId], queryFn: () => incentiveStatement(orgId, `${month}-01`, staffId || undefined), enabled: Boolean(orgId && month) });
  const rows = useMemo(() => report.data ?? [], [report.data]);
  const byStaff = useMemo(() => {
    const m = new Map<string, { name: string; role: string; total: number; rows: typeof rows }>();
    for (const r of rows) {
      const k = r.staff_id ?? '';
      const e = m.get(k) ?? { name: r.staff_name ?? '', role: String(r.role ?? ''), total: 0, rows: [] };
      e.total += toNumber(r.earned);
      e.rows.push(r);
      m.set(k, e);
    }
    return Array.from(m.entries());
  }, [rows]);
  const onExport = () => exportToExcel(`incentives-${month}`, rows.map((r) => ({ Salesman: r.staff_name, Scheme: r.scheme_name, Basis: BASIS_LABEL[r.basis ?? ''] ?? r.basis, Rate: toNumber(r.rate), Sales: toNumber(r.sales), Returns: toNumber(r.returns), 'Net sales': toNumber(r.net_sales), Collection: toNumber(r.collection), Boxes: toNumber(r.boxes), 'New shops': toNumber(r.new_customers), Base: toNumber(r.base_value), Earned: toNumber(r.earned) })), 'Incentives');
  return (
    <div className="space-y-3">
      <div className="no-print flex flex-wrap items-end gap-2">
        <Field label="Month" htmlFor="in-month"><Input id="in-month" type="month" className="h-8 w-40" value={month} onChange={(e) => setMonth(e.target.value)} /></Field>
        <Field label="Salesman" htmlFor="in-staff">
          <NativeSelect id="in-staff" className="h-8 w-48" value={staffId} onChange={(e) => setStaffId(e.target.value)}>
            <option value="">Everyone</option>
            {(staff.data ?? []).filter((s) => s.is_active && (s.role === 'sales_exec' || s.role === 'driver')).map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </NativeSelect>
        </Field>
        <Actions onExport={onExport} disabled={!rows.length}>
          {rows.length > 0 && <Badge variant="secondary">Total {amount(sumBy(rows, (r) => r.earned))}</Badge>}
        </Actions>
      </div>
      <PrintTitle title="Incentive statement" range={month} />
      <Status isLoading={report.isLoading} error={report.error} empty={!rows.length} emptyText="No active schemes, or no sales executives / drivers. Schemes are set under Setup → Incentives.">
        <Table>
          <TableHeader><TableRow><TableHead>Salesman</TableHead><TableHead>Scheme</TableHead><TableHead>Basis</TableHead><TableHead className="text-right">Net sales</TableHead><TableHead className="text-right">Collection</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead className="text-right">New shops</TableHead><TableHead className="text-right">Base</TableHead><TableHead className="text-right">Earned</TableHead></TableRow></TableHeader>
          <TableBody>
            {byStaff.map(([id, s]) => (
              <Fragment key={id}>
                {s.rows.map((r, i) => (
                  <TableRow key={`${id}-${r.scheme_id ?? i}`}>
                    <TableCell className="font-medium">{i === 0 ? <>{s.name}<div className="text-xs text-muted-foreground">{s.role === 'driver' ? 'Driver' : 'Sales executive'}</div></> : ''}</TableCell>
                    <TableCell>{r.scheme_name}</TableCell>
                    <TableCell className="text-muted-foreground">{BASIS_LABEL[r.basis ?? ''] ?? r.basis}{r.basis !== 'slab' && ` · ${qty(r.rate, 2)}`}</TableCell>
                    <TableCell className="num">{i === 0 ? amount(r.net_sales) : ''}</TableCell>
                    <TableCell className="num">{i === 0 ? amount(r.collection) : ''}</TableCell>
                    <TableCell className="num">{i === 0 ? qty(r.boxes) : ''}</TableCell>
                    <TableCell className="num">{i === 0 ? int(r.new_customers) : ''}</TableCell>
                    <TableCell className="num text-muted-foreground">{r.basis === 'per_box' ? qty(r.base_value) : r.basis === 'per_new_customer' ? int(r.base_value) : amount(r.base_value)}</TableCell>
                    <TableCell className="num font-medium">{amount(r.earned)}</TableCell>
                  </TableRow>
                ))}
                <TableRow className="bg-muted/40">
                  <TableCell colSpan={8} className="text-right text-sm">{s.name} total</TableCell>
                  <TableCell className="num font-semibold">{amount(s.total)}</TableCell>
                </TableRow>
              </Fragment>
            ))}
          </TableBody>
        </Table>
      </Status>
      <p className="text-xs text-muted-foreground">Sales are the invoices stamped with the salesman (the customer's salesman, else whoever made the bill), less returns against them. Collection is what they collected; a bounced cheque comes back as a negative. Pay the amount through Payments → staff as usual.</p>
    </div>
  );
}
