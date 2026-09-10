import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { Download, Plus } from 'lucide-react';
import { useState } from 'react';
import { Link, NavLink, useNavigate, useParams } from 'react-router-dom';
import { DeleteButton } from '@/components/DeleteButton';
import { MasterCrud, type MasterConfig } from '@/components/MasterCrud';
import { PageHeader } from '@/components/PageHeader';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { useDebounced } from '@/hooks/use-debounced';
import { toastError } from '@/hooks/use-toast';
import { deleteDocument } from '@/features/search/deletes';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, int } from '@/lib/format';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { cn } from '@/lib/utils';
import { createSupplier, getPurchase, getPurchaseLines, listAllPurchases, listPurchases, listSuppliers, removeSupplier, updateSupplier, type SupplierRow } from '../api';
import { PurchaseEditor } from '../components/PurchaseEditor';
import { supplierSchema, type SupplierInput } from '../schema';

const orNull = (s: string) => (s.trim() === '' ? null : s.trim());

export function PurchasesPage({ tab = 'purchases' }: { tab?: 'purchases' | 'suppliers' }) {
  const perms = usePermissions();
  const canEdit = perms.canEdit('purchases');
  return (
    <div className="space-y-3">
      <PageHeader
        title="Purchases"
        description="Raw material and bought-in goods. Stock and the supplier ledger post on save."
        actions={
          canEdit && tab === 'purchases' ? (
            <Button asChild size="sm">
              <Link to="/purchases/new">
                <Plus /> New purchase
              </Link>
            </Button>
          ) : undefined
        }
      />
      <nav className="flex gap-1 border-b" aria-label="Purchases sections">
        {[
          { to: '/purchases', label: 'Purchases', end: true },
          { to: '/purchases/suppliers', label: 'Suppliers', end: false },
        ].map((t) => (
          <NavLink key={t.to} to={t.to} end={t.end} className={({ isActive }) => cn('-mb-px border-b-2 px-3 py-1.5 text-sm', isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}>
            {t.label}
          </NavLink>
        ))}
      </nav>
      {tab === 'suppliers' ? <SuppliersPanel canEdit={canEdit} canDelete={perms.canDelete('purchases')} /> : <PurchaseList />}
    </div>
  );
}

function PurchaseList() {
  const navigate = useNavigate();
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const debounced = useDebounced(search);
  const filters = { search: debounced, from, to };
  const purchases = useQuery({
    queryKey: ['purchases', 'list', { ...filters, page, pageSize }],
    queryFn: () => listPurchases({ ...filters, page, pageSize }),
    placeholderData: keepPreviousData,
  });

  const onExport = async () => {
    try {
      const rows = await listAllPurchases(filters);
      exportToExcel(
        'purchases',
        rows.map((r) => ({ Date: dateDMY(r.bill_date), 'Bill no.': r.bill_no, Supplier: r.supplier_name, Godown: r.location_name, Subtotal: Number(r.subtotal ?? 0), 'Other charges': Number(r.other_charges ?? 0), Total: Number(r.total ?? 0), Paid: Number(r.paid_amount ?? 0) })),
        'Purchases',
      );
    } catch (err) {
      toastError(err, 'Export failed');
    }
  };

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Bill no. or supplier…" aria-label="Search purchases" className="h-8 w-56" value={search} onChange={(ev) => { setSearch(ev.target.value); setPage(1); }} />
        <Input type="date" aria-label="From date" className="h-8 w-40" value={from} onChange={(ev) => { setFrom(ev.target.value); setPage(1); }} />
        <Input type="date" aria-label="To date" className="h-8 w-40" value={to} onChange={(ev) => { setTo(ev.target.value); setPage(1); }} />
        <Button variant="outline" size="sm" onClick={onExport} disabled={!purchases.data?.total}>
          <Download /> Excel
        </Button>
      </div>
      {purchases.isLoading ? (
        <Spinner />
      ) : purchases.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load purchases: {purchases.error.message}</p>
      ) : purchases.data && purchases.data.rows.length === 0 ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No purchases match.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Date</TableHead>
                <TableHead>Bill no.</TableHead>
                <TableHead>Supplier</TableHead>
                <TableHead>Godown</TableHead>
                <TableHead className="text-right">Lines</TableHead>
                <TableHead className="text-right">Total</TableHead>
                <TableHead className="text-right">Paid</TableHead>
                {perms.canDelete('purchases') && <TableHead className="w-10" />}
              </TableRow>
            </TableHeader>
            <TableBody>
              {purchases.data?.rows.map((r) => (
                <TableRow key={r.id} className="cursor-pointer" tabIndex={0} onClick={() => navigate(`/purchases/${r.id}`)} onKeyDown={(ev) => ev.key === 'Enter' && navigate(`/purchases/${r.id}`)}>
                  <TableCell>{dateDMY(r.bill_date)}</TableCell>
                  <TableCell className="font-medium">{r.bill_no ?? '—'}</TableCell>
                  <TableCell>{r.supplier_name ?? <span className="text-muted-foreground">cash purchase</span>}</TableCell>
                  <TableCell className="text-muted-foreground">{r.location_name}</TableCell>
                  <TableCell className="num">{int(r.line_count)}</TableCell>
                  <TableCell className="num">{amount(r.total)}</TableCell>
                  <TableCell className="num">{amount(r.paid_amount)}</TableCell>
                  {perms.canDelete('purchases') && (
                    <TableCell onClick={(ev) => ev.stopPropagation()}>
                      <DeleteButton
                        label={`purchase ${r.bill_no ?? ''}`.trim()}
                        detail="The goods come back out of stock and the ledger entry is reversed. If any of them have already been sold on, the screen will refuse and name the product."
                        invalidate={['purchases']}
                        onDelete={() => deleteDocument('purchase', r.id ?? '')}
                      />
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {purchases.data && <Pager page={page} pageSize={pageSize} total={purchases.data.total} onPage={setPage} onPageSize={(n) => { setPageSize(n); setPage(1); }} />}
    </div>
  );
}

function SuppliersPanel({ canEdit, canDelete }: { canEdit: boolean; canDelete: boolean }) {
  const config: MasterConfig<SupplierRow & { id: string }, SupplierInput> = {
    key: 'suppliers',
    title: 'Suppliers',
    singular: 'Supplier',
    exportName: 'suppliers',
    description: 'Who raw material and bought-in goods come from. Payable = opening balance + unpaid purchases − payments.',
    columns: [
      { key: 'name', label: 'Name' },
      { key: 'town', label: 'Town' },
      { key: 'mobile1', label: 'Mobile' },
      { key: 'payable', label: 'Payable', align: 'right', render: (r) => amount(r.payable), exportValue: (r) => Number(r.payable ?? 0) },
      { key: 'is_active', label: 'Active' },
    ],
    fields: [
      { name: 'name', label: 'Name', autoFocus: true },
      { name: 'mobile1', label: 'Mobile', half: true },
      { name: 'town', label: 'Town', half: true },
      { name: 'opening_balance', label: 'Opening balance (₹ we owe)', type: 'number', step: '0.01', half: true },
      { name: 'is_active', label: 'Active', type: 'checkbox', half: true },
    ],
    schema: supplierSchema,
    defaults: { name: '', mobile1: '', town: '', opening_balance: 0, is_active: true },
    toForm: (r) => ({ name: r.name ?? '', mobile1: r.mobile1 ?? '', town: r.town ?? '', opening_balance: Number(r.opening_balance ?? 0), is_active: r.is_active ?? true }),
    rowLabel: (r) => r.name ?? '',
    list: async () => (await listSuppliers()).filter((r): r is SupplierRow & { id: string } => Boolean(r.id)),
    create: (v) => createSupplier({ name: v.name, mobile1: orNull(v.mobile1), town: orNull(v.town), opening_balance: v.opening_balance, is_active: v.is_active }),
    update: (id, v) => updateSupplier(id, { name: v.name, mobile1: orNull(v.mobile1), town: orNull(v.town), opening_balance: v.opening_balance, is_active: v.is_active }),
    remove: removeSupplier,
    canEdit,
    canDelete,
  };
  return <MasterCrud config={config} />;
}

export function PurchaseNewPage() {
  const perms = usePermissions();
  if (!perms.canEdit('purchases')) return <p className="text-sm text-muted-foreground">Your role cannot enter purchases.</p>;
  return (
    <div className="space-y-4">
      <PageHeader title="New purchase" actions={<Button asChild variant="ghost" size="sm"><Link to="/purchases">← Purchases</Link></Button>} />
      <PurchaseEditor />
    </div>
  );
}

export function PurchaseViewPage() {
  const { id } = useParams();
  const purchase = useQuery({ queryKey: ['purchases', 'one', id], queryFn: () => getPurchase(id ?? ''), enabled: Boolean(id) });
  const lines = useQuery({ queryKey: ['purchases', 'lines', id], queryFn: () => getPurchaseLines(id ?? ''), enabled: Boolean(id) });
  if (purchase.isLoading || lines.isLoading) return <Spinner label="Loading purchase…" />;
  if (!purchase.data || !lines.data) return <p role="alert" className="text-sm text-destructive">Purchase not found.</p>;
  const p = purchase.data;
  return (
    <div className="space-y-4">
      <PageHeader title={`Purchase ${p.bill_no ?? ''}`} description={`${dateDMY(p.bill_date)} · ${p.supplier_name ?? 'cash purchase'} · into ${p.location_name ?? ''}`} actions={<Button asChild variant="ghost" size="sm"><Link to="/purchases">← Purchases</Link></Button>} />
      <div className="rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Item</TableHead>
              <TableHead>Name</TableHead>
              <TableHead className="text-right">Qty</TableHead>
              <TableHead>Unit</TableHead>
              <TableHead className="text-right">Rate</TableHead>
              <TableHead className="text-right">Amount</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {lines.data.map((l) => (
              <TableRow key={l.id}>
                <TableCell className="font-medium">{l.item_code}</TableCell>
                <TableCell>{l.item_name}</TableCell>
                <TableCell className="num">{Number(l.qty ?? 0)}</TableCell>
                <TableCell>{l.uom_code}</TableCell>
                <TableCell className="num">{amount(l.rate)}</TableCell>
                <TableCell className="num">{amount(l.amount)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
      <div className="ml-auto max-w-xs space-y-1 text-sm">
        <div className="flex justify-between"><span className="text-muted-foreground">Subtotal</span><span className="tabular-nums">{amount(p.subtotal)}</span></div>
        <div className="flex justify-between"><span className="text-muted-foreground">Other charges</span><span className="tabular-nums">{amount(p.other_charges)}</span></div>
        <div className="flex justify-between font-semibold"><span>Total</span><span className="tabular-nums">{amount(p.total)}</span></div>
        <div className="flex justify-between"><span className="text-muted-foreground">Paid now</span><span className="tabular-nums">{amount(p.paid_amount)}</span></div>
      </div>
      <p className="text-xs text-muted-foreground">Purchases are final on save. Corrections go through a purchase return or a stock adjustment.</p>
    </div>
  );
}
