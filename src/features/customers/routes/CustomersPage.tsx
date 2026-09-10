import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { Download, Plus, Upload } from 'lucide-react';
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { DeleteButton } from '@/components/DeleteButton';
import { PageHeader } from '@/components/PageHeader';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { deleteMaster } from '@/features/search/deletes';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { routesApi } from '@/features/setup/api';
import { useDebounced } from '@/hooks/use-debounced';
import { toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, money } from '@/lib/format';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { listAllCustomers, listCustomers, updateCustomer, type CustomerRow } from '../api';
import { CustomerDialog } from '../components/CustomerDialog';

export function CustomersPage() {
  const perms = usePermissions();
  // Arrived from the global search: open on that customer.
  const [params] = useSearchParams();
  const [search, setSearch] = useState(params.get('q') ?? '');
  const [routeId, setRouteId] = useState('');
  const [includeInactive, setIncludeInactive] = useState(false);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const [editing, setEditing] = useState<{ mode: 'new' } | { mode: 'edit'; row: CustomerRow } | null>(null);
  const debounced = useDebounced(search);

  const filters = { search: debounced, routeId, includeInactive };
  const customers = useQuery({
    queryKey: ['customers', 'list', { ...filters, page, pageSize }],
    queryFn: () => listCustomers({ ...filters, page, pageSize }),
    placeholderData: keepPreviousData,
  });
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list });
  const canEdit = perms.canEdit('customers');

  const onExport = async () => {
    try {
      const rows = await listAllCustomers(filters);
      exportToExcel(
        'customers',
        rows.map((r) => ({
          Code: r.code,
          Name: r.name,
          Town: r.town,
          'Mobile 1': r.mobile1,
          'Mobile 2': r.mobile2,
          'Mobile 3': r.mobile3,
          Route: r.route_name,
          'Price group': r.price_group,
          'Credit limit': Number(r.credit_limit ?? 0),
          'Opening balance': Number(r.opening_balance ?? 0),
          Outstanding: Number(r.outstanding ?? 0),
          WhatsApp: r.whatsapp_opt_in,
          Active: r.is_active,
        })),
        'Customers',
      );
    } catch (err) {
      toastError(err, 'Export failed');
    }
  };

  return (
    <div className="space-y-3">
      <PageHeader
        title="Customers"
        description="Shops and parties billed on the van routes. Mobile 1 is the duplicate check, on this form and on import."
        actions={
          <>
            <Button variant="outline" size="sm" onClick={onExport} disabled={!customers.data?.total}>
              <Download /> Excel
            </Button>
            {canEdit && perms.canEdit('setup') && (
              <Button asChild variant="outline" size="sm">
                <Link to="/setup/import">
                  <Upload /> Bulk import
                </Link>
              </Button>
            )}
            {canEdit && (
              <Button size="sm" onClick={() => setEditing({ mode: 'new' })}>
                <Plus /> New customer
              </Button>
            )}
          </>
        }
      />

      <div className="flex flex-wrap items-center gap-2">
        <Input
          type="search"
          placeholder="Search name, mobile, town, code…"
          aria-label="Search customers"
          value={search}
          onChange={(e) => {
            setSearch(e.target.value);
            setPage(1);
          }}
          className="h-8 w-64"
        />
        <NativeSelect
          aria-label="Route"
          className="h-8 w-44"
          value={routeId}
          onChange={(e) => {
            setRouteId(e.target.value);
            setPage(1);
          }}
        >
          <option value="">All routes</option>
          {(routes.data ?? []).map((r) => (
            <option key={r.id} value={r.id}>
              {r.name}
            </option>
          ))}
        </NativeSelect>
        <label className="flex items-center gap-1 text-sm">
          <Checkbox
            checked={includeInactive}
            onChange={(e) => {
              setIncludeInactive(e.target.checked);
              setPage(1);
            }}
          />
          Show inactive
        </label>
      </div>

      {customers.isLoading ? (
        <Spinner />
      ) : customers.error ? (
        <p role="alert" className="text-sm text-destructive">
          Could not load customers: {customers.error.message}
        </p>
      ) : customers.data && customers.data.rows.length === 0 ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
          No customers match.{canEdit && ' Add one, or bulk import from Setup → Import data.'}
        </p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Code</TableHead>
                <TableHead>Name</TableHead>
                <TableHead>Town</TableHead>
                <TableHead>Mobile</TableHead>
                <TableHead>Route</TableHead>
                <TableHead>Price group</TableHead>
                <TableHead className="text-right">Credit limit</TableHead>
                <TableHead className="text-right">Outstanding</TableHead>
                {perms.canDelete('customers') && <TableHead className="w-10" />}
              </TableRow>
            </TableHeader>
            <TableBody>
              {customers.data?.rows.map((r) => (
                <TableRow
                  key={r.id}
                  className={canEdit ? 'cursor-pointer' : undefined}
                  tabIndex={canEdit ? 0 : undefined}
                  onClick={() => canEdit && setEditing({ mode: 'edit', row: r })}
                  onKeyDown={(e) => canEdit && e.key === 'Enter' && setEditing({ mode: 'edit', row: r })}
                >
                  <TableCell className="text-muted-foreground">{r.code ?? '—'}</TableCell>
                  <TableCell className="font-medium">
                    {r.name}
                    {!r.is_active && (
                      <Badge variant="outline" className="ml-1">
                        inactive
                      </Badge>
                    )}
                  </TableCell>
                  <TableCell>{r.town ?? '—'}</TableCell>
                  <TableCell className="tabular-nums">{r.mobile1 ?? '—'}</TableCell>
                  <TableCell>{r.route_name ?? '—'}</TableCell>
                  <TableCell>{r.price_group}</TableCell>
                  <TableCell className="num">{amount(r.credit_limit)}</TableCell>
                  <TableCell className={Number(r.outstanding ?? 0) > 0 ? 'num font-medium' : 'num'}>{money(r.outstanding)}</TableCell>
                  {perms.canDelete('customers') && (
                    // stopPropagation, or the row's own click opens the edit dialog behind this one.
                    <TableCell onClick={(e) => e.stopPropagation()}>
                      <DeleteButton
                        label={r.name ?? 'customer'}
                        detail="A customer who has ever been billed cannot be deleted — the screen will say so and you can set them inactive instead."
                        invalidate={['customers']}
                        onDelete={() => deleteMaster('customer', r.id ?? '')}
                        onDeactivate={() => updateCustomer(r.id ?? '', { is_active: false })}
                        deactivateWarning={
                          Number(r.outstanding ?? 0) !== 0
                            ? `${r.name} still owes ${money(r.outstanding)}. Setting them inactive stops new bills; the outstanding stays on the books and in the ageing report until it is collected or written off.`
                            : undefined
                        }
                      />
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {customers.data && (
        <Pager
          page={page}
          pageSize={pageSize}
          total={customers.data.total}
          onPage={setPage}
          onPageSize={(n) => {
            setPageSize(n);
            setPage(1);
          }}
        />
      )}

      {editing && (
        <CustomerDialog
          key={editing.mode === 'edit' ? editing.row.id : 'new'}
          customer={editing.mode === 'edit' ? editing.row : undefined}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}
