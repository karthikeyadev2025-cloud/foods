import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { Download, Plus } from 'lucide-react';
import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { DeleteButton } from '@/components/DeleteButton';
import { PageHeader } from '@/components/PageHeader';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { useDebounced } from '@/hooks/use-debounced';
import { toastError } from '@/hooks/use-toast';
import { deleteDocument } from '@/features/search/deletes';
import { exportToExcel } from '@/lib/export';
import { amount, dateDMY, qty } from '@/lib/format';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { INVOICE_STATUSES, listAllInvoices, listInvoices, type InvoiceStatus } from '../api';

const tone: Record<InvoiceStatus, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  draft: 'outline',
  confirmed: 'default',
  dispatched: 'secondary',
  delivered: 'secondary',
  cancelled: 'destructive',
};

export function InvoicesPage() {
  const navigate = useNavigate();
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState<InvoiceStatus | ''>('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const debounced = useDebounced(search);
  const filters = { search: debounced, status, from, to };

  const invoices = useQuery({
    queryKey: ['invoices', 'list', { ...filters, page, pageSize }],
    queryFn: () => listInvoices({ ...filters, page, pageSize }),
    placeholderData: keepPreviousData,
  });

  const onExport = async () => {
    try {
      const rows = await listAllInvoices(filters);
      exportToExcel(
        'invoices',
        rows.map((r) => ({
          'Invoice no.': r.invoice_no,
          Date: dateDMY(r.invoice_date),
          Customer: r.customer_name,
          Town: r.customer_town,
          Status: r.status,
          Boxes: Number(r.total_boxes ?? 0),
          Subtotal: Number(r.subtotal ?? 0),
          Freight: Number(r.freight ?? 0),
          'Net amount': Number(r.total ?? 0),
          Received: Number(r.received ?? 0),
          Returned: Number(r.returned ?? 0),
          Balance: Number(r.balance ?? 0),
          Vehicle: r.vehicle_number,
        })),
        'Invoices',
      );
    } catch (err) {
      toastError(err, 'Export failed');
    }
  };

  return (
    <div className="space-y-3">
      <PageHeader
        title="Sales invoices"
        description="Stock leaves on confirm. Assign the vehicle after the invoice exists."
        actions={
          <>
            <Button variant="outline" size="sm" onClick={onExport} disabled={!invoices.data?.total}>
              <Download /> Excel
            </Button>
            {perms.canEdit('invoices') && (
              <Button asChild size="sm">
                <Link to="/invoices/new">
                  <Plus /> New invoice
                </Link>
              </Button>
            )}
          </>
        }
      />
      <div className="flex flex-wrap items-center gap-2">
        <Input
          type="search"
          placeholder="Invoice no., customer, town…"
          aria-label="Search invoices"
          className="h-8 w-60"
          value={search}
          onChange={(ev) => {
            setSearch(ev.target.value);
            setPage(1);
          }}
        />
        <NativeSelect aria-label="Status" className="h-8 w-36" value={status} onChange={(ev) => { setStatus(ev.target.value as InvoiceStatus | ''); setPage(1); }}>
          <option value="">All statuses</option>
          {INVOICE_STATUSES.map((s) => (
            <option key={s.value} value={s.value}>
              {s.label}
            </option>
          ))}
        </NativeSelect>
        <Input type="date" aria-label="From date" className="h-8 w-40" value={from} onChange={(ev) => { setFrom(ev.target.value); setPage(1); }} />
        <Input type="date" aria-label="To date" className="h-8 w-40" value={to} onChange={(ev) => { setTo(ev.target.value); setPage(1); }} />
      </div>

      {invoices.isLoading ? (
        <Spinner />
      ) : invoices.error ? (
        <p role="alert" className="text-sm text-destructive">
          Could not load invoices: {invoices.error.message}
        </p>
      ) : invoices.data && invoices.data.rows.length === 0 ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No invoices match.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>No.</TableHead>
                <TableHead>Date</TableHead>
                <TableHead>Customer</TableHead>
                <TableHead>Town</TableHead>
                <TableHead className="text-right">Boxes</TableHead>
                <TableHead className="text-right">Net</TableHead>
                <TableHead className="text-right">Balance</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Vehicle</TableHead>
                {perms.canDelete('invoices') && <TableHead className="w-10" />}
              </TableRow>
            </TableHeader>
            <TableBody>
              {invoices.data?.rows.map((r) => (
                <TableRow
                  key={r.id}
                  className="cursor-pointer"
                  tabIndex={0}
                  onClick={() => navigate(`/invoices/${r.id}`)}
                  onKeyDown={(ev) => ev.key === 'Enter' && navigate(`/invoices/${r.id}`)}
                >
                  <TableCell className="font-medium">{r.invoice_no}</TableCell>
                  <TableCell>{dateDMY(r.invoice_date)}</TableCell>
                  <TableCell>{r.customer_name}</TableCell>
                  <TableCell className="text-muted-foreground">{r.customer_town ?? '—'}</TableCell>
                  <TableCell className="num">{qty(r.total_boxes)}</TableCell>
                  <TableCell className="num">{amount(r.total)}</TableCell>
                  <TableCell className={Number(r.balance ?? 0) > 0 && r.status !== 'cancelled' ? 'num font-medium' : 'num text-muted-foreground'}>
                    {r.status === 'cancelled' || r.status === 'draft' ? '—' : amount(r.balance)}
                  </TableCell>
                  <TableCell>
                    <Badge variant={tone[(r.status ?? 'draft') as InvoiceStatus]}>{r.status}</Badge>
                  </TableCell>
                  <TableCell className="text-muted-foreground">{r.vehicle_number ?? '—'}</TableCell>
                  {perms.canDelete('invoices') && (
                    <TableCell onClick={(ev) => ev.stopPropagation()}>
                      <DeleteButton
                        label={`invoice ${r.invoice_no}`}
                        detail="The bill is marked cancelled rather than removed — the customer has a copy of that number. Its goods go back into stock and the ledger entry is reversed."
                        invalidate={['invoices']}
                        onDelete={() => deleteDocument('invoice', r.id ?? '')}
                      />
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {invoices.data && (
        <Pager page={page} pageSize={pageSize} total={invoices.data.total} onPage={setPage} onPageSize={(n) => { setPageSize(n); setPage(1); }} />
      )}
    </div>
  );
}
