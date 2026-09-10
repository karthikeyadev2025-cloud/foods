import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { Download, Plus } from 'lucide-react';
import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { PageHeader } from '@/components/PageHeader';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { DeleteButton } from '@/components/DeleteButton';
import { deleteMaster } from '@/features/search/deletes';
import { usePermissions } from '@/features/auth/hooks';
import { packTypesApi, sectionsApi } from '@/features/setup/api';
import { useDebounced } from '@/hooks/use-debounced';
import { toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { amount, int, qty } from '@/lib/format';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { listAllItems, listItems, type ItemType } from '../api';
import { ITEM_TYPES } from '../schema';

export function ItemsPage() {
  const navigate = useNavigate();
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const [sectionId, setSectionId] = useState('');
  const [packTypeId, setPackTypeId] = useState('');
  const [type, setType] = useState('');
  const [includeInactive, setIncludeInactive] = useState(false);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const debounced = useDebounced(search);

  const filters = { search: debounced, sectionId, packTypeId, type: type as ItemType | '', includeInactive };
  const items = useQuery({
    queryKey: ['items', 'list', { ...filters, page, pageSize }],
    queryFn: () => listItems({ ...filters, page, pageSize }),
    placeholderData: keepPreviousData,
  });
  const sections = useQuery({ queryKey: ['setup', 'sections'], queryFn: sectionsApi.list });
  const packTypes = useQuery({ queryKey: ['setup', 'pack_types'], queryFn: packTypesApi.list });

  const onExport = async () => {
    try {
      const rows = await listAllItems(filters);
      exportToExcel(
        'items',
        rows.map((r) => ({
          Code: r.item_code,
          Name: r.name,
          Type: r.type,
          Pack: r.pack_code,
          Section: r.section_name,
          'Units/box': r.units_per_box,
          'Pieces/unit': r.pieces_per_unit,
          MRP: r.mrp_per_piece === null ? null : Number(r.mrp_per_piece),
          'Unit rate': Number(r.unit_rate ?? 0),
          'Box rate': Number(r.box_rate ?? 0),
          'Purchase rate': Number(r.purchase_rate ?? 0),
          'Stock (units)': Number(r.stock_base ?? 0),
          'Stock (boxes)': r.units_per_box ? Number(r.stock_base ?? 0) / r.units_per_box : null,
          Active: r.is_active,
        })),
        'Items',
      );
    } catch (err) {
      toastError(err, 'Export failed');
    }
  };

  const reset = <T,>(setter: (v: T) => void) => (v: T) => {
    setter(v);
    setPage(1);
  };

  return (
    <div className="space-y-3">
      <PageHeader
        title="Items"
        description="The item master. Packing and rates are set on each product and derived everywhere else."
        actions={
          <>
            <Button variant="outline" size="sm" onClick={onExport} disabled={!items.data?.total}>
              <Download /> Excel
            </Button>
            {perms.canEdit('items') && (
              <Button asChild size="sm">
                <Link to="/items/new">
                  <Plus /> Add product
                </Link>
              </Button>
            )}
          </>
        }
      />

      <div className="flex flex-wrap items-center gap-2">
        <Input
          type="search"
          placeholder="Search code or name…"
          aria-label="Search items"
          value={search}
          onChange={(e) => reset(setSearch)(e.target.value)}
          className="h-8 w-56"
        />
        <NativeSelect aria-label="Section" className="h-8 w-48" value={sectionId} onChange={(e) => reset(setSectionId)(e.target.value)}>
          <option value="">All sections</option>
          {(sections.data ?? []).map((s) => (
            <option key={s.id} value={s.id}>
              {s.code ? `${s.code} ` : ''}
              {s.name}
            </option>
          ))}
        </NativeSelect>
        <NativeSelect aria-label="Pack type" className="h-8 w-32" value={packTypeId} onChange={(e) => reset(setPackTypeId)(e.target.value)}>
          <option value="">All packs</option>
          {(packTypes.data ?? []).map((p) => (
            <option key={p.id} value={p.id}>
              {p.code}
            </option>
          ))}
        </NativeSelect>
        <NativeSelect aria-label="Type" className="h-8 w-40" value={type} onChange={(e) => reset(setType)(e.target.value)}>
          <option value="">All types</option>
          {ITEM_TYPES.map((t) => (
            <option key={t.value} value={t.value}>
              {t.label.split(' (')[0]}
            </option>
          ))}
        </NativeSelect>
        <label className="flex items-center gap-1 text-sm">
          <Checkbox checked={includeInactive} onChange={(e) => reset(setIncludeInactive)(e.target.checked)} />
          Show inactive
        </label>
      </div>

      {items.isLoading ? (
        <Spinner />
      ) : items.error ? (
        <p role="alert" className="text-sm text-destructive">
          Could not load items: {items.error.message}
        </p>
      ) : items.data && items.data.rows.length === 0 ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
          No items match. {perms.canEdit('items') && 'Add a product, or import the price list under Setup → Import data.'}
        </p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Code</TableHead>
                <TableHead>Item name</TableHead>
                <TableHead>Pack</TableHead>
                <TableHead>Section</TableHead>
                <TableHead className="text-right">Units/box</TableHead>
                <TableHead className="text-right">Pcs/unit</TableHead>
                <TableHead className="text-right">MRP</TableHead>
                <TableHead className="text-right">Unit rate</TableHead>
                <TableHead className="text-right">Box rate</TableHead>
                <TableHead className="text-right">Stock (boxes)</TableHead>
                {perms.canDelete('items') && <TableHead className="w-10" />}
              </TableRow>
            </TableHeader>
            <TableBody>
              {items.data?.rows.map((r) => {
                const boxes = r.units_per_box ? Number(r.stock_base ?? 0) / r.units_per_box : 0;
                return (
                  <TableRow
                    key={r.id}
                    className="cursor-pointer"
                    tabIndex={0}
                    onClick={() => navigate(`/items/${r.id}`)}
                    onKeyDown={(e) => e.key === 'Enter' && navigate(`/items/${r.id}`)}
                  >
                    <TableCell className="font-medium">
                      {r.item_code}
                      {!r.is_active && (
                        <Badge variant="outline" className="ml-1">
                          inactive
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell>{r.name}</TableCell>
                    <TableCell>{r.pack_code ?? '—'}</TableCell>
                    <TableCell className="text-muted-foreground">{r.section_name ?? '—'}</TableCell>
                    <TableCell className="num">{int(r.units_per_box)}</TableCell>
                    <TableCell className="num">{int(r.pieces_per_unit)}</TableCell>
                    <TableCell className="num">{r.mrp_per_piece === null ? '—' : amount(r.mrp_per_piece)}</TableCell>
                    <TableCell className="num">{amount(r.unit_rate)}</TableCell>
                    <TableCell className="num">{amount(r.box_rate)}</TableCell>
                    <TableCell className={boxes < 0 ? 'num font-medium text-destructive' : 'num'}>{qty(boxes)}</TableCell>
                    {perms.canDelete('items') && (
                      // stopPropagation, or the row's own click opens the item behind the dialog.
                      <TableCell onClick={(e) => e.stopPropagation()}>
                        <DeleteButton
                          label={r.name ?? r.item_code ?? 'product'}
                          detail="A product that has ever been bought, sold or counted cannot be deleted — the screen will say so and you can set it inactive instead."
                          invalidate={['items']}
                          onDelete={() => deleteMaster('item', r.id ?? '')}
                        />
                      </TableCell>
                    )}
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}

      {items.data && (
        <Pager
          page={page}
          pageSize={pageSize}
          total={items.data.total}
          onPage={setPage}
          onPageSize={(n) => {
            setPageSize(n);
            setPage(1);
          }}
        />
      )}
    </div>
  );
}
