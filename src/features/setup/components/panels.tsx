import { useQuery } from '@tanstack/react-query';
import { listCashBankAccounts } from '@/features/accounts/api';
import { usePermissions } from '@/features/auth/hooks';
import {
  expenseHeadsApi,
  listStaff,
  numberSeriesApi,
  packTypesApi,
  receiptModesApi,
  reorderSections,
  routesApi,
  sectionsApi,
  stockLocationsApi,
  uomsApi,
  type Row,
} from '../api';
import {
  DOC_TYPES,
  LOCATION_KINDS,
  RESET_PERIODS,
  UOM_BASES,
  expenseHeadSchema,
  numberSeriesSchema,
  orNull,
  packTypeSchema,
  receiptModeSchema,
  routeSchema,
  sectionSchema,
  stockLocationSchema,
  uomSchema,
  type ExpenseHeadInput,
  type NumberSeriesInput,
  type PackTypeInput,
  type ReceiptModeInput,
  type RouteInput,
  type SectionInput,
  type StockLocationInput,
  type UomInput,
} from '../schema';
import { MasterCrud, type MasterConfig } from '@/components/MasterCrud';

const activeCol = { key: 'is_active', label: 'Active' } as const;

function useSetupRights() {
  const p = usePermissions();
  return { canEdit: p.canEdit('setup'), canDelete: p.canDelete('setup') };
}

// ------------------------------------------------------------------
// Units of measure
// ------------------------------------------------------------------
const UOM_STANDARD: UomInput[] = [
  { code: 'BOX', name: 'Box', basis: 'box', weight_g: 0, sort_order: 1, is_active: true },
  { code: 'JAR', name: 'Jar', basis: 'unit', weight_g: 0, sort_order: 2, is_active: true },
  { code: 'PACK', name: 'Pack', basis: 'unit', weight_g: 0, sort_order: 3, is_active: true },
  { code: 'LB', name: 'L.B', basis: 'unit', weight_g: 0, sort_order: 4, is_active: true },
  { code: 'TRY', name: 'Tray', basis: 'unit', weight_g: 0, sort_order: 5, is_active: true },
  { code: 'PC', name: 'Piece', basis: 'piece', weight_g: 0, sort_order: 6, is_active: true },
  { code: 'KG', name: 'Kilogram', basis: 'weight', weight_g: 1000, sort_order: 7, is_active: true },
  { code: 'GM', name: 'Gram', basis: 'weight', weight_g: 1, sort_order: 8, is_active: true },
];

export function UomsPanel({ compact }: { compact?: boolean }) {
  const rights = useSetupRights();
  const config: MasterConfig<Row<'uoms'>, UomInput> = {
    key: 'uoms',
    title: 'Units of measure',
    singular: 'Unit',
    exportName: 'units',
    description:
      'Every quantity in the system is a number plus one of these. The basis says how it converts: a box is units_per_box × pieces_per_unit, a unit (jar / pack / L.B) is pieces_per_unit pieces, weight units carry grams per 1.',
    columns: [
      { key: 'code', label: 'Code' },
      { key: 'name', label: 'Name' },
      { key: 'basis', label: 'Basis' },
      { key: 'weight_g', label: 'Grams', align: 'right' },
      { key: 'sort_order', label: 'Order', align: 'right' },
      activeCol,
    ],
    fields: [
      { name: 'code', label: 'Code', half: true, autoFocus: true, lockOnEdit: true, placeholder: 'JAR' },
      { name: 'name', label: 'Name', half: true },
      { name: 'basis', label: 'Basis', type: 'select', options: UOM_BASES },
      { name: 'weight_g', label: 'Grams per 1 (weight basis only)', type: 'number', half: true, step: '0.001' },
      { name: 'sort_order', label: 'Sort order', type: 'number', half: true },
      { name: 'is_active', label: 'Active', type: 'checkbox' },
    ],
    schema: uomSchema,
    defaults: { code: '', name: '', basis: 'unit', weight_g: 0, sort_order: 0, is_active: true },
    toForm: (r) => ({
      code: r.code,
      name: r.name,
      basis: r.basis,
      weight_g: Number(r.weight_g ?? 0),
      sort_order: r.sort_order,
      is_active: r.is_active,
    }),
    rowLabel: (r) => r.code,
    list: uomsApi.list,
    create: (v) => uomsApi.create({ ...v, code: v.code.toUpperCase(), weight_g: v.weight_g || null }),
    update: (id, v) => uomsApi.update(id, { ...v, code: v.code.toUpperCase(), weight_g: v.weight_g || null }),
    remove: uomsApi.remove,
    suggestions: {
      label: 'Add standard units',
      rows: UOM_STANDARD,
      isPresent: (existing, s) => existing.some((e) => e.code === s.code),
    },
    ...rights,
  };
  return <MasterCrud config={config} compact={compact} />;
}

// ------------------------------------------------------------------
// Pack types
// ------------------------------------------------------------------
const PACK_STANDARD: PackTypeInput[] = [
  { code: 'JAR', name: 'Jar', sort_order: 1, is_active: true },
  { code: 'PACK', name: 'Pack', sort_order: 2, is_active: true },
  { code: 'L.B', name: 'L.B', sort_order: 3, is_active: true },
  { code: 'KG', name: 'Loose (kg)', sort_order: 4, is_active: true },
  { code: 'TRY', name: 'Tray', sort_order: 5, is_active: true },
  { code: 'BOX', name: 'Box', sort_order: 6, is_active: true },
];

export function PackTypesPanel({ compact }: { compact?: boolean }) {
  const rights = useSetupRights();
  const config: MasterConfig<Row<'pack_types'>, PackTypeInput> = {
    key: 'pack_types',
    title: 'Pack types',
    singular: 'Pack type',
    exportName: 'pack-types',
    description: 'The "Pack" column on the stock report and on every print. A label only; conversion comes from the item.',
    columns: [
      { key: 'code', label: 'Code' },
      { key: 'name', label: 'Name' },
      { key: 'sort_order', label: 'Order', align: 'right' },
      activeCol,
    ],
    fields: [
      { name: 'code', label: 'Code', half: true, autoFocus: true, lockOnEdit: true, placeholder: 'L.B' },
      { name: 'name', label: 'Name', half: true },
      { name: 'sort_order', label: 'Sort order', type: 'number', half: true },
      { name: 'is_active', label: 'Active', type: 'checkbox', half: true },
    ],
    schema: packTypeSchema,
    defaults: { code: '', name: '', sort_order: 0, is_active: true },
    toForm: (r) => ({ code: r.code, name: r.name ?? '', sort_order: r.sort_order, is_active: r.is_active }),
    rowLabel: (r) => r.code,
    list: packTypesApi.list,
    create: (v) => packTypesApi.create({ ...v, code: v.code.toUpperCase(), name: orNull(v.name) }),
    update: (id, v) => packTypesApi.update(id, { ...v, code: v.code.toUpperCase(), name: orNull(v.name) }),
    remove: packTypesApi.remove,
    suggestions: {
      label: 'Add standard pack types',
      rows: PACK_STANDARD,
      isPresent: (existing, s) => existing.some((e) => e.code === s.code),
    },
    ...rights,
  };
  return <MasterCrud config={config} compact={compact} />;
}

// ------------------------------------------------------------------
// Receipt modes
// ------------------------------------------------------------------
const MODE_STANDARD: ReceiptModeInput[] = [
  { code: 'CASH', name: 'Cash', is_collection: true, needs_reference: false, is_cheque: false, account_id: '', sort_order: 1, is_active: true },
  { code: 'BANK', name: 'Bank transfer', is_collection: true, needs_reference: true, is_cheque: false, account_id: '', sort_order: 2, is_active: true },
  { code: 'UPI', name: 'UPI', is_collection: true, needs_reference: true, is_cheque: false, account_id: '', sort_order: 3, is_active: true },
  { code: 'CHEQUE', name: 'Cheque', is_collection: true, needs_reference: true, is_cheque: true, account_id: '', sort_order: 4, is_active: true },
  // TODO(client): BSR meaning unknown — collection mode or deduction head? Kept as collection until confirmed.
  { code: 'BSR', name: 'BSR', is_collection: true, needs_reference: true, is_cheque: false, account_id: '', sort_order: 5, is_active: true },
  { code: 'BRK', name: 'Breakage', is_collection: false, needs_reference: false, is_cheque: false, account_id: '', sort_order: 6, is_active: true },
  { code: 'ADJ', name: 'Adjustment', is_collection: false, needs_reference: false, is_cheque: false, account_id: '', sort_order: 7, is_active: true },
];

export function ReceiptModesPanel({ compact }: { compact?: boolean }) {
  const rights = useSetupRights();
  const accounts = useQuery({ queryKey: ['accounts', 'cash_bank'], queryFn: listCashBankAccounts });
  const accountOptions = [{ value: '', label: 'By kind (CASH → cash, others → bank)' }, ...(accounts.data ?? []).filter((a) => a.is_active).map((a) => ({ value: a.id ?? '', label: `${a.name} (${a.kind})` }))];
  const config: MasterConfig<Row<'receipt_modes'>, ReceiptModeInput> = {
    key: 'receipt_modes',
    title: 'Receipt modes',
    singular: 'Receipt mode',
    exportName: 'receipt-modes',
    description:
      'Each active mode becomes a column on the receipts register. "Collection" modes are money in; deduction heads reduce the bill instead. "Needs reference" asks for a cheque / UTR / slip number. A cheque mode books the cheque (Accounts → Cheques) instead of the bank until it clears.',
    columns: [
      { key: 'code', label: 'Code' },
      { key: 'name', label: 'Name' },
      { key: 'is_collection', label: 'Collection' },
      { key: 'needs_reference', label: 'Needs ref.' },
      { key: 'is_cheque', label: 'Cheque' },
      { key: 'account_id', label: 'Lands in', render: (r) => accounts.data?.find((a) => a.id === r.account_id)?.name ?? <span className="text-muted-foreground">by kind</span> },
      { key: 'sort_order', label: 'Order', align: 'right' },
      activeCol,
    ],
    fields: [
      { name: 'code', label: 'Code', half: true, autoFocus: true, lockOnEdit: true, placeholder: 'UPI' },
      { name: 'name', label: 'Name', half: true },
      { name: 'is_collection', label: 'Collection (money in)', type: 'checkbox', half: true },
      { name: 'needs_reference', label: 'Needs a reference number', type: 'checkbox', half: true },
      { name: 'is_cheque', label: 'This is a cheque mode', type: 'checkbox', half: true },
      { name: 'account_id', label: 'Money lands in', type: 'select', options: accountOptions, half: true },
      { name: 'sort_order', label: 'Sort order', type: 'number', half: true },
      { name: 'is_active', label: 'Active', type: 'checkbox', half: true },
    ],
    schema: receiptModeSchema,
    defaults: { code: '', name: '', is_collection: true, needs_reference: false, is_cheque: false, account_id: '', sort_order: 0, is_active: true },
    toForm: (r) => ({
      code: r.code,
      name: r.name,
      is_collection: r.is_collection,
      needs_reference: r.needs_reference,
      is_cheque: r.is_cheque,
      account_id: r.account_id ?? '',
      sort_order: r.sort_order,
      is_active: r.is_active,
    }),
    rowLabel: (r) => r.code,
    list: receiptModesApi.list,
    create: (v) => receiptModesApi.create({ ...v, code: v.code.toUpperCase(), account_id: v.account_id || null }),
    update: (id, v) => receiptModesApi.update(id, { ...v, code: v.code.toUpperCase(), account_id: v.account_id || null }),
    remove: receiptModesApi.remove,
    suggestions: {
      label: 'Add standard modes',
      rows: MODE_STANDARD,
      isPresent: (existing, s) => existing.some((e) => e.code === s.code),
    },
    ...rights,
  };
  return <MasterCrud config={config} compact={compact} />;
}

// ------------------------------------------------------------------
// Expense heads
// ------------------------------------------------------------------
const EXPENSE_STANDARD: ExpenseHeadInput[] = [
  'Wages',
  'Raw material',
  'Packing material',
  'Fuel',
  'Freight',
  'Electricity',
  'Rent',
  'Repairs',
  'Miscellaneous',
].map((name) => ({ name, is_active: true }));

export function ExpenseHeadsPanel({ compact }: { compact?: boolean }) {
  const rights = useSetupRights();
  const config: MasterConfig<Row<'expense_heads'>, ExpenseHeadInput> = {
    key: 'expense_heads',
    title: 'Expense heads',
    singular: 'Expense head',
    exportName: 'expense-heads',
    description: 'Categories for payments that are not to a supplier or a staff member.',
    columns: [{ key: 'name', label: 'Name' }, activeCol],
    fields: [
      { name: 'name', label: 'Name', autoFocus: true },
      { name: 'is_active', label: 'Active', type: 'checkbox' },
    ],
    schema: expenseHeadSchema,
    defaults: { name: '', is_active: true },
    toForm: (r) => ({ name: r.name, is_active: r.is_active }),
    rowLabel: (r) => r.name,
    list: expenseHeadsApi.list,
    create: (v) => expenseHeadsApi.create(v),
    update: (id, v) => expenseHeadsApi.update(id, v),
    remove: expenseHeadsApi.remove,
    suggestions: {
      label: 'Add common heads',
      rows: EXPENSE_STANDARD,
      isPresent: (existing, s) => existing.some((e) => e.name.toLowerCase() === s.name.toLowerCase()),
    },
    ...rights,
  };
  return <MasterCrud config={config} compact={compact} />;
}

// ------------------------------------------------------------------
// Sections (mestri groups)
// ------------------------------------------------------------------
export function SectionsPanel({ compact }: { compact?: boolean }) {
  const rights = useSetupRights();
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const mestris = (staff.data ?? []).filter((s) => s.is_mestry && s.is_active);
  const mestriName = (id: string | null) => mestris.find((m) => m.id === id)?.full_name ?? null;

  const config: MasterConfig<Row<'sections'>, SectionInput> = {
    key: 'sections',
    title: 'Sections & mestris',
    singular: 'Section',
    exportName: 'sections',
    description:
      'The stock report groups and sub-totals items by section, in this sort order. Each section is run by a mestri (a staff member flagged as mestri under Users). Codes like S-10 are optional — OTHERS (UNDALU) and R.K.BAKERY have none.',
    columns: [
      { key: 'sort_order', label: 'Order', align: 'right' },
      { key: 'code', label: 'Code' },
      { key: 'name', label: 'Section' },
      { key: 'mestri_id', label: 'Mestri', render: (r) => mestriName(r.mestri_id) ?? '—', exportValue: (r) => mestriName(r.mestri_id) },
      activeCol,
    ],
    fields: [
      { name: 'code', label: 'Code (optional)', half: true, placeholder: 'S-10' },
      { name: 'sort_order', label: 'Order on stock report', type: 'number', half: true },
      { name: 'name', label: 'Section name', autoFocus: true, placeholder: 'RAMA KRISHNA MESTRI' },
      {
        name: 'mestri_id',
        label: 'Mestri',
        type: 'select',
        options: [{ value: '', label: '— none —' }, ...mestris.map((m) => ({ value: m.id, label: m.full_name }))],
        help: mestris.length ? undefined : 'No staff are flagged as mestri yet. Add them under Users.',
      },
      { name: 'is_active', label: 'Active', type: 'checkbox' },
    ],
    schema: sectionSchema,
    defaults: { code: '', name: '', mestri_id: '', sort_order: 0, is_active: true },
    toForm: (r) => ({
      code: r.code ?? '',
      name: r.name,
      mestri_id: r.mestri_id ?? '',
      sort_order: r.sort_order,
      is_active: r.is_active,
    }),
    rowLabel: (r) => r.name,
    list: sectionsApi.list,
    create: (v) => sectionsApi.create({ ...v, code: orNull(v.code)?.toUpperCase() ?? null, mestri_id: orNull(v.mestri_id) }),
    update: (id, v) => sectionsApi.update(id, { ...v, code: orNull(v.code)?.toUpperCase() ?? null, mestri_id: orNull(v.mestri_id) }),
    remove: sectionsApi.remove,
    reorder: reorderSections,
    ...rights,
  };
  return <MasterCrud config={config} compact={compact} />;
}

// ------------------------------------------------------------------
// Routes (van lines)
// ------------------------------------------------------------------
export function RoutesPanel({ compact }: { compact?: boolean }) {
  const rights = useSetupRights();
  const config: MasterConfig<Row<'routes'>, RouteInput> = {
    key: 'routes',
    title: 'Routes',
    singular: 'Route',
    exportName: 'routes',
    description: 'Van routes. Customers and vehicles are assigned to a route; reports and reminders can be filtered by it.',
    columns: [
      { key: 'name', label: 'Route' },
      { key: 'towns', label: 'Towns', render: (r) => (r.towns ?? []).join(', ') || '—', exportValue: (r) => (r.towns ?? []).join(', ') },
      activeCol,
    ],
    fields: [
      { name: 'name', label: 'Route name', autoFocus: true, placeholder: 'Macherla line' },
      { name: 'towns', label: 'Towns on this route', type: 'textarea', help: 'Comma separated.' },
      { name: 'is_active', label: 'Active', type: 'checkbox' },
    ],
    schema: routeSchema,
    defaults: { name: '', towns: '', is_active: true },
    toForm: (r) => ({ name: r.name, towns: (r.towns ?? []).join(', '), is_active: r.is_active }),
    rowLabel: (r) => r.name,
    list: routesApi.list,
    create: (v) => routesApi.create({ name: v.name, towns: splitTowns(v.towns), is_active: v.is_active }),
    update: (id, v) => routesApi.update(id, { name: v.name, towns: splitTowns(v.towns), is_active: v.is_active }),
    remove: routesApi.remove,
    ...rights,
  };
  return <MasterCrud config={config} compact={compact} />;
}

function splitTowns(s: string): string[] {
  return s
    .split(',')
    .map((t) => t.trim())
    .filter(Boolean);
}

// ------------------------------------------------------------------
// Stock locations
// ------------------------------------------------------------------
const LOCATION_STANDARD: StockLocationInput[] = [
  { name: 'Main godown', kind: 'godown', is_active: true },
  { name: 'Production floor', kind: 'production_floor', is_active: true },
];

export function StockLocationsPanel({ compact }: { compact?: boolean }) {
  const rights = useSetupRights();
  const config: MasterConfig<Row<'stock_locations'>, StockLocationInput> = {
    key: 'stock_locations',
    title: 'Stock locations',
    singular: 'Location',
    exportName: 'stock-locations',
    description:
      'Every godown and the production floor. Vehicles get their own location automatically when created, because van stock is real stock.',
    columns: [
      { key: 'name', label: 'Name' },
      { key: 'kind', label: 'Kind', render: (r) => LOCATION_KINDS.find((k) => k.value === r.kind)?.label ?? r.kind },
      activeCol,
    ],
    fields: [
      { name: 'name', label: 'Name', autoFocus: true },
      { name: 'kind', label: 'Kind', type: 'select', options: LOCATION_KINDS },
      { name: 'is_active', label: 'Active', type: 'checkbox' },
    ],
    schema: stockLocationSchema,
    defaults: { name: '', kind: 'godown', is_active: true },
    toForm: (r) => ({ name: r.name, kind: r.kind, is_active: r.is_active }),
    rowLabel: (r) => r.name,
    list: stockLocationsApi.list,
    create: (v) => stockLocationsApi.create(v),
    update: (id, v) => stockLocationsApi.update(id, v),
    remove: stockLocationsApi.remove,
    suggestions: {
      label: 'Add godown + production floor',
      rows: LOCATION_STANDARD,
      isPresent: (existing, s) => existing.some((e) => e.kind === s.kind),
    },
    ...rights,
  };
  return <MasterCrud config={config} compact={compact} />;
}

// ------------------------------------------------------------------
// Number series
// ------------------------------------------------------------------
const SERIES_STANDARD: NumberSeriesInput[] = DOC_TYPES.map((d) => ({
  doc_type: d.value,
  prefix: '',
  suffix: '',
  width: 4,
  next_number: 1,
  reset_period: 'never',
}));

function preview(v: NumberSeriesInput): string {
  return `${v.prefix}${String(v.next_number).padStart(v.width, '0')}${v.suffix}`;
}

export function NumberSeriesPanel({ compact }: { compact?: boolean }) {
  const rights = useSetupRights();
  const docLabel = (t: string) => DOC_TYPES.find((d) => d.value === t)?.label ?? t;
  const config: MasterConfig<Row<'number_series'>, NumberSeriesInput> = {
    key: 'number_series',
    title: 'Document numbering',
    singular: 'Number series',
    exportName: 'number-series',
    description:
      'One series per document type: prefix, digits, suffix and when the counter resets. A series is created automatically the first time a document type is used if none exists.',
    columns: [
      { key: 'doc_type', label: 'Document', render: (r) => docLabel(r.doc_type), exportValue: (r) => docLabel(r.doc_type) },
      { key: 'prefix', label: 'Prefix' },
      { key: 'width', label: 'Digits', align: 'right' },
      { key: 'suffix', label: 'Suffix' },
      { key: 'next_number', label: 'Next', align: 'right' },
      {
        key: 'preview',
        label: 'Next number looks like',
        render: (r) =>
          preview({
            doc_type: r.doc_type,
            prefix: r.prefix ?? '',
            suffix: r.suffix ?? '',
            width: r.width,
            next_number: Number(r.next_number),
            reset_period: r.reset_period as NumberSeriesInput['reset_period'],
          }),
        exportValue: (r) => `${r.prefix ?? ''}${String(r.next_number).padStart(r.width, '0')}${r.suffix ?? ''}`,
      },
      {
        key: 'reset_period',
        label: 'Resets',
        render: (r) => RESET_PERIODS.find((p) => p.value === r.reset_period)?.label ?? r.reset_period,
      },
    ],
    fields: [
      { name: 'doc_type', label: 'Document type', type: 'select', options: DOC_TYPES, lockOnEdit: true },
      { name: 'prefix', label: 'Prefix', half: true, placeholder: 'INV/' },
      { name: 'suffix', label: 'Suffix', half: true, placeholder: '/26-27' },
      { name: 'width', label: 'Digits', type: 'number', half: true },
      { name: 'next_number', label: 'Next number', type: 'number', half: true },
      { name: 'reset_period', label: 'Reset counter', type: 'select', options: RESET_PERIODS },
    ],
    schema: numberSeriesSchema,
    defaults: { doc_type: 'invoice', prefix: '', suffix: '', width: 4, next_number: 1, reset_period: 'never' },
    toForm: (r) => ({
      doc_type: r.doc_type,
      prefix: r.prefix ?? '',
      suffix: r.suffix ?? '',
      width: r.width,
      next_number: Number(r.next_number),
      reset_period: r.reset_period as NumberSeriesInput['reset_period'],
    }),
    rowLabel: (r) => docLabel(r.doc_type),
    list: numberSeriesApi.list,
    create: (v) => numberSeriesApi.create(v),
    update: (id, v) => numberSeriesApi.update(id, v),
    remove: numberSeriesApi.remove,
    suggestions: {
      label: 'Create a series for every document',
      rows: SERIES_STANDARD,
      isPresent: (existing, s) => existing.some((e) => e.doc_type === s.doc_type),
    },
    ...rights,
  };
  return <MasterCrud config={config} compact={compact} />;
}
