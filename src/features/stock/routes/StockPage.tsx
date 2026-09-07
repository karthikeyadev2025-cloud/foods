import { useQuery } from '@tanstack/react-query';
import { Download } from 'lucide-react';
import { Fragment, useMemo, useState } from 'react';
import { NavLink } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe } from '@/features/auth/hooks';
import { searchItems, type ItemRow } from '@/features/items/api';
import { sectionsApi, stockLocationsApi } from '@/features/setup/api';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, dateTimeDMY, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { closingStock, listItemStock, stockMovements, type ClosingStockRow } from '../api';

const TABS = [
  { key: 'closing', label: 'Closing stock' },
  { key: 'movements', label: 'Movements' },
  { key: 'low', label: 'Low stock' },
] as const;
export type StockTab = (typeof TABS)[number]['key'];

export function StockPage({ tab = 'closing' }: { tab?: StockTab }) {
  return (
    <div className="space-y-3">
      <PageHeader title="Stock" description="Every figure is a SUM over the ledger. Negative stock is shown and flagged, never hidden." />
      <nav className="flex gap-1 border-b" aria-label="Stock reports">
        {TABS.map((t) => (
          <NavLink key={t.key} to={t.key === 'closing' ? '/stock' : `/stock/${t.key}`} end className={({ isActive }) => cn('-mb-px border-b-2 px-3 py-1.5 text-sm', isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}>
            {t.label}
          </NavLink>
        ))}
      </nav>
      {tab === 'closing' && <ClosingStock />}
      {tab === 'movements' && <Movements />}
      {tab === 'low' && <LowStock />}
    </div>
  );
}

/** Reproduces STOCK_REPORT.xlsx: grouped by mestri section with sub-totals, in boxes. */
function ClosingStock() {
  const me = useMe();
  const [date, setDate] = useState(toISODate());
  const [locationId, setLocationId] = useState('');
  const [sectionId, setSectionId] = useState('');
  const [hideZero, setHideZero] = useState(false);
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const sections = useQuery({ queryKey: ['setup', 'sections'], queryFn: sectionsApi.list });
  const orgId = me.data?.org_id ?? '';
  const report = useQuery({
    queryKey: ['stock', 'closing', orgId, date, locationId, sectionId],
    queryFn: () => closingStock(orgId, date, locationId, sectionId),
    enabled: Boolean(orgId && date),
  });

  const groups = useMemo(() => {
    const rows = (report.data ?? []).filter((r) => !hideZero || toNumber(r.opening) !== 0 || toNumber(r.purchase) !== 0 || toNumber(r.sales) !== 0 || toNumber(r.closing) !== 0);
    const map = new Map<string, { key: string; code: string | null; name: string; rows: ClosingStockRow[] }>();
    for (const r of rows) {
      const key = r.section_id ?? 'none';
      if (!map.has(key)) map.set(key, { key, code: r.section_code, name: r.section_name ?? 'OTHERS', rows: [] });
      map.get(key)?.rows.push(r);
    }
    return [...map.values()];
  }, [report.data, hideZero]);

  const sum = (rows: ClosingStockRow[], k: 'opening' | 'purchase' | 'sales' | 'closing') => rows.reduce((s, r) => s + toNumber(r[k]), 0);
  const all = groups.flatMap((g) => g.rows);
  const negatives = all.filter((r) => r.is_negative).length;

  const onExport = () =>
    exportToExcel(
      `stock-report-${date}`,
      groups.flatMap((g) => [
        ...g.rows.map((r) => ({ Section: `${g.code ? `${g.code} ` : ''}${g.name}`, 'Item Code': r.item_code, Pack: r.pack, 'Group / Item Name': r.item_name, Opening: toNumber(r.opening), Purchase: toNumber(r.purchase), Sales: toNumber(r.sales), Closing: toNumber(r.closing) })),
        { Section: `${g.name} total`, 'Item Code': '', Pack: '', 'Group / Item Name': '', Opening: sum(g.rows, 'opening'), Purchase: sum(g.rows, 'purchase'), Sales: sum(g.rows, 'sales'), Closing: sum(g.rows, 'closing') },
      ]),
      `Stock ${dateDMY(date)}`,
    );

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-end gap-2">
        <Field label="As on" htmlFor="cs-date"><Input id="cs-date" type="date" className="h-8 w-40" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
        <Field label="Location" htmlFor="cs-loc">
          <NativeSelect id="cs-loc" className="h-8 w-48" value={locationId} onChange={(e) => setLocationId(e.target.value)}>
            <option value="">All locations</option>
            {(locations.data ?? []).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
          </NativeSelect>
        </Field>
        <Field label="Section" htmlFor="cs-sec">
          <NativeSelect id="cs-sec" className="h-8 w-52" value={sectionId} onChange={(e) => setSectionId(e.target.value)}>
            <option value="">All sections</option>
            {(sections.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.code ? `${s.code} ` : ''}{s.name}</option>)}
          </NativeSelect>
        </Field>
        <label className="flex items-center gap-1 pb-2 text-sm"><Checkbox checked={hideZero} onChange={(e) => setHideZero(e.target.checked)} /> Hide all-zero rows</label>
        <span className="ml-auto flex items-center gap-2 pb-1">
          {negatives > 0 && <Badge variant="destructive">{negatives} negative</Badge>}
          <Button variant="outline" size="sm" onClick={onExport} disabled={!all.length}><Download /> Excel</Button>
        </span>
      </div>
      {report.isLoading ? <Spinner /> : report.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load the report: {report.error.message}</p>
      ) : groups.length === 0 ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No items.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-24">Item Code</TableHead><TableHead className="w-16">Pack</TableHead><TableHead>Group / Item Name</TableHead>
                <TableHead className="w-24 text-right">Opening</TableHead><TableHead className="w-24 text-right">Purchase</TableHead><TableHead className="w-24 text-right">Sales</TableHead><TableHead className="w-24 text-right">Closing</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {groups.map((g) => (
                <Fragment key={g.key}>
                  <TableRow className="bg-muted/50 hover:bg-muted/50">
                    <TableCell colSpan={7} className="font-semibold">{g.code ? `${g.code} ` : ''}{g.name}</TableCell>
                  </TableRow>
                  {g.rows.map((r) => (
                    <TableRow key={r.item_id ?? r.item_code ?? ''} className={cn(r.is_negative && 'bg-red-50')}>
                      <TableCell className="font-medium">{r.item_code}</TableCell>
                      <TableCell className="text-muted-foreground">{r.pack ?? '—'}</TableCell>
                      <TableCell>{r.item_name}</TableCell>
                      <TableCell className="num">{qty(r.opening)}</TableCell>
                      <TableCell className="num">{toNumber(r.purchase) ? qty(r.purchase) : ''}</TableCell>
                      <TableCell className="num">{toNumber(r.sales) ? qty(r.sales) : ''}</TableCell>
                      <TableCell className={cn('num font-medium', r.is_negative && 'text-destructive')}>{qty(r.closing)}</TableCell>
                    </TableRow>
                  ))}
                  <TableRow className="bg-muted/30 hover:bg-muted/30">
                    <TableCell colSpan={3} className="text-right text-xs uppercase text-muted-foreground">{g.name} total</TableCell>
                    <TableCell className="num font-medium">{qty(sum(g.rows, 'opening'))}</TableCell>
                    <TableCell className="num font-medium">{qty(sum(g.rows, 'purchase'))}</TableCell>
                    <TableCell className="num font-medium">{qty(sum(g.rows, 'sales'))}</TableCell>
                    <TableCell className="num font-medium">{qty(sum(g.rows, 'closing'))}</TableCell>
                  </TableRow>
                </Fragment>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell colSpan={3} className="text-right">Grand total (boxes)</TableCell>
                <TableCell className="num">{qty(sum(all, 'opening'))}</TableCell><TableCell className="num">{qty(sum(all, 'purchase'))}</TableCell>
                <TableCell className="num">{qty(sum(all, 'sales'))}</TableCell><TableCell className="num">{qty(sum(all, 'closing'))}</TableCell>
              </TableRow>
            </TableFooter>
          </Table>
        </div>
      )}
    </div>
  );
}

function Movements() {
  const [item, setItem] = useState<ItemRow | null>(null);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [locationId, setLocationId] = useState('');
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const moves = useQuery({ queryKey: ['stock', 'movements', item?.id, from, to, locationId], queryFn: () => stockMovements(item?.id ?? '', from, to, locationId), enabled: Boolean(item?.id) });
  const upb = item?.units_per_box ?? 0;

  const onExport = () =>
    exportToExcel(`movements-${item?.item_code ?? ''}`, (moves.data ?? []).map((m) => ({ Date: dateDMY(m.txn_date), Type: m.txn_type, Location: m.location_name, Reference: m.ref_no, 'Qty (units)': toNumber(m.qty_base), 'Qty (boxes)': toNumber(m.boxes), 'Balance (units)': toNumber(m.balance_base), 'Balance (boxes)': toNumber(m.balance_boxes), Rate: toNumber(m.rate) })), 'Movements');

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Item" htmlFor="mv-item" className="w-80">
          <Combobox<ItemRow> id="mv-item" value={item} onChange={setItem} search={(q) => searchItems(q)} queryKey="items-all" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code} — ${i.name}`} renderOption={(i) => <span><span className="font-medium">{i.item_code}</span> {i.name}</span>} placeholder="Code or name…" autoFocus eager />
        </Field>
        <Field label="From" htmlFor="mv-from"><Input id="mv-from" type="date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label="To" htmlFor="mv-to"><Input id="mv-to" type="date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
        <Field label="Location" htmlFor="mv-loc">
          <NativeSelect id="mv-loc" className="h-8 w-44" value={locationId} onChange={(e) => setLocationId(e.target.value)}>
            <option value="">All locations</option>
            {(locations.data ?? []).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
          </NativeSelect>
        </Field>
        <Button variant="outline" size="sm" className="ml-auto" onClick={onExport} disabled={!moves.data?.length}><Download /> Excel</Button>
      </div>
      {!item ? <p className="text-sm text-muted-foreground">Pick an item to see its ledger.</p> : moves.isLoading ? <Spinner /> : moves.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load movements: {moves.error.message}</p>
      ) : !moves.data?.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No movements in this range.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Date</TableHead><TableHead>Type</TableHead><TableHead>Location</TableHead><TableHead>Reference</TableHead><TableHead className="text-right">In</TableHead><TableHead className="text-right">Out</TableHead><TableHead className="text-right">Balance (boxes)</TableHead><TableHead className="text-right">Balance (units)</TableHead><TableHead>Entered</TableHead></TableRow></TableHeader>
            <TableBody>
              {moves.data.map((m) => {
                const q = toNumber(m.qty_base);
                return (
                  <TableRow key={m.id ?? ''}>
                    <TableCell>{dateDMY(m.txn_date)}</TableCell>
                    <TableCell><Badge variant="outline">{m.txn_type?.replace('_', ' ')}</Badge></TableCell>
                    <TableCell>{m.location_name}</TableCell>
                    <TableCell className="text-muted-foreground">{m.ref_no ?? '—'}</TableCell>
                    <TableCell className="num">{q > 0 ? `${qty(q / (upb || 1))} bx` : ''}</TableCell>
                    <TableCell className="num">{q < 0 ? `${qty(-q / (upb || 1))} bx` : ''}</TableCell>
                    <TableCell className={cn('num font-medium', toNumber(m.balance_base) < 0 && 'text-destructive')}>{qty(m.balance_boxes)}</TableCell>
                    <TableCell className="num text-muted-foreground">{qty(m.balance_base, 3)}</TableCell>
                    <TableCell className="text-xs text-muted-foreground">{dateTimeDMY(m.created_at)}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}

function LowStock() {
  const [lowOnly, setLowOnly] = useState(true);
  const rows = useQuery({ queryKey: ['stock', 'items', lowOnly], queryFn: () => listItemStock({ lowOnly }) });
  const onExport = () => exportToExcel('low-stock', (rows.data ?? []).map((r) => ({ 'Item Code': r.item_code, Item: r.name, Section: r.section_name, 'Stock (boxes)': toNumber(r.boxes), 'Stock (units)': toNumber(r.qty_base), 'Reorder level (units)': toNumber(r.reorder_level), Low: r.is_low, Negative: r.is_negative })), 'Low stock');
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <label className="flex items-center gap-1 text-sm"><Checkbox checked={lowOnly} onChange={(e) => setLowOnly(e.target.checked)} /> Only items at or below their reorder level</label>
        <Button variant="outline" size="sm" className="ml-auto" onClick={onExport} disabled={!rows.data?.length}><Download /> Excel</Button>
      </div>
      {rows.isLoading ? <Spinner /> : rows.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load: {rows.error.message}</p>
      ) : !rows.data?.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">Nothing is low. Reorder levels are set per item on Add Product.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Item Code</TableHead><TableHead>Item</TableHead><TableHead>Section</TableHead><TableHead className="text-right">Stock (boxes)</TableHead><TableHead className="text-right">Stock (units)</TableHead><TableHead className="text-right">Reorder (units)</TableHead><TableHead className="text-right">Value at rate</TableHead></TableRow></TableHeader>
            <TableBody>
              {rows.data.map((r) => (
                <TableRow key={r.item_id ?? ''} className={cn(r.is_negative && 'bg-red-50')}>
                  <TableCell className="font-medium">{r.item_code}</TableCell><TableCell>{r.name}</TableCell><TableCell className="text-muted-foreground">{r.section_name ?? '—'}</TableCell>
                  <TableCell className={cn('num', r.is_negative && 'text-destructive')}>{qty(r.boxes)}</TableCell><TableCell className="num">{qty(r.qty_base, 3)}</TableCell><TableCell className="num text-muted-foreground">{qty(r.reorder_level, 3)}</TableCell>
                  <TableCell className="num text-muted-foreground">{amount(0)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}
