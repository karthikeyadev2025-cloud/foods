import { currentOrgId } from '@/features/auth/api';
import { expectOk, expectOne, expectRows, supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Tables = Database['public']['Tables'];

/** Lookup tables the Setup screens manage with the same list / create / update / delete shape. */
export type MasterTable =
  | 'uoms'
  | 'pack_types'
  | 'receipt_modes'
  | 'expense_heads'
  | 'sections'
  | 'stock_locations'
  | 'number_series'
  | 'routes';

export type Row<T extends MasterTable> = Tables[T]['Row'];
export type Insert<T extends MasterTable> = Tables[T]['Insert'];
export type Update<T extends MasterTable> = Tables[T]['Update'];

export interface MasterApi<T extends MasterTable> {
  table: T;
  list: () => Promise<Row<T>[]>;
  /** `org_id` is stamped here so no screen ever has to know it; RLS rejects anything else anyway. */
  create: (values: Omit<Insert<T>, 'org_id'>) => Promise<Row<T>>;
  update: (id: string, values: Update<T>) => Promise<Row<T>>;
  remove: (id: string) => Promise<void>;
}

// supabase-js cannot type `from(table)` when the table name is a type parameter,
// so each lookup gets its own literal-typed implementation. Same shape, no casts.

export const uomsApi: MasterApi<'uoms'> = {
  table: 'uoms',
  list: () => expectRows(supabase.from('uoms').select('*').order('sort_order').order('code')),
  create: async (v) => expectOne(supabase.from('uoms').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id, v) => expectOne(supabase.from('uoms').update(v).eq('id', id).select('*').single()),
  remove: (id) => expectOk(supabase.from('uoms').delete().eq('id', id)),
};

export const packTypesApi: MasterApi<'pack_types'> = {
  table: 'pack_types',
  list: () => expectRows(supabase.from('pack_types').select('*').order('sort_order').order('code')),
  create: async (v) =>
    expectOne(supabase.from('pack_types').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id, v) => expectOne(supabase.from('pack_types').update(v).eq('id', id).select('*').single()),
  remove: (id) => expectOk(supabase.from('pack_types').delete().eq('id', id)),
};

export const receiptModesApi: MasterApi<'receipt_modes'> = {
  table: 'receipt_modes',
  list: () => expectRows(supabase.from('receipt_modes').select('*').order('sort_order').order('code')),
  create: async (v) =>
    expectOne(supabase.from('receipt_modes').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id, v) => expectOne(supabase.from('receipt_modes').update(v).eq('id', id).select('*').single()),
  remove: (id) => expectOk(supabase.from('receipt_modes').delete().eq('id', id)),
};

export const expenseHeadsApi: MasterApi<'expense_heads'> = {
  table: 'expense_heads',
  list: () => expectRows(supabase.from('expense_heads').select('*').order('name')),
  create: async (v) =>
    expectOne(supabase.from('expense_heads').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id, v) => expectOne(supabase.from('expense_heads').update(v).eq('id', id).select('*').single()),
  remove: (id) => expectOk(supabase.from('expense_heads').delete().eq('id', id)),
};

export const sectionsApi: MasterApi<'sections'> = {
  table: 'sections',
  list: () => expectRows(supabase.from('sections').select('*').order('sort_order').order('name')),
  create: async (v) =>
    expectOne(supabase.from('sections').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id, v) => expectOne(supabase.from('sections').update(v).eq('id', id).select('*').single()),
  remove: (id) => expectOk(supabase.from('sections').delete().eq('id', id)),
};

export const stockLocationsApi: MasterApi<'stock_locations'> = {
  table: 'stock_locations',
  list: () => expectRows(supabase.from('stock_locations').select('*').order('name')),
  create: async (v) =>
    expectOne(supabase.from('stock_locations').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id, v) => expectOne(supabase.from('stock_locations').update(v).eq('id', id).select('*').single()),
  remove: (id) => expectOk(supabase.from('stock_locations').delete().eq('id', id)),
};

export const routesApi: MasterApi<'routes'> = {
  table: 'routes',
  list: () => expectRows(supabase.from('routes').select('*').order('name')),
  create: async (v) => expectOne(supabase.from('routes').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id, v) => expectOne(supabase.from('routes').update(v).eq('id', id).select('*').single()),
  remove: (id) => expectOk(supabase.from('routes').delete().eq('id', id)),
};

/** Drag-to-reorder: sort_order becomes the position in `ids` (db/08_masters.sql). */
export async function reorderSections(ids: string[]): Promise<void> {
  const { error } = await supabase.rpc('reorder_sections', { p_ids: ids });
  if (error) throw error;
}

export const numberSeriesApi: MasterApi<'number_series'> = {
  table: 'number_series',
  list: () => expectRows(supabase.from('number_series').select('*').order('doc_type')),
  create: async (v) =>
    expectOne(supabase.from('number_series').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id, v) => expectOne(supabase.from('number_series').update(v).eq('id', id).select('*').single()),
  remove: (id) => expectOk(supabase.from('number_series').delete().eq('id', id)),
};

// ------------------------------------------------------------------
// Org profile
// ------------------------------------------------------------------
export type Org = Tables['orgs']['Row'];

export function getOrg(): Promise<Org> {
  return expectOne(supabase.from('orgs').select('*').single());
}

export function updateOrg(id: string, values: Tables['orgs']['Update']): Promise<Org> {
  return expectOne(supabase.from('orgs').update(values).eq('id', id).select('*').single());
}

// ------------------------------------------------------------------
// Staff / users
// ------------------------------------------------------------------
export type Staff = Tables['staff']['Row'];
export type StaffRole = Database['public']['Enums']['staff_role'];

export function listStaff(): Promise<Staff[]> {
  return expectRows(supabase.from('staff').select('*').order('full_name'));
}

export function updateStaff(id: string, values: Tables['staff']['Update']): Promise<Staff> {
  return expectOne(supabase.from('staff').update(values).eq('id', id).select('*').single());
}

export interface CreateUserInput {
  email: string;
  password: string;
  full_name: string;
  phone: string | null;
  role: StaffRole;
  is_mestry: boolean;
  daily_wage: number;
}

/**
 * Creating a login needs the service role, so it runs in the `create-user` edge
 * function (supabase/functions/create-user). The function checks the caller is an
 * owner/admin of the org and inserts the staff row.
 */
export async function createUser(input: CreateUserInput): Promise<Staff> {
  const { data, error } = await supabase.functions.invoke<{ staff: Staff } | { error: string }>('create-user', {
    body: input,
  });
  if (error) throw error;
  if (!data || 'error' in data) throw new Error(data?.error ?? 'create-user returned nothing');
  return data.staff;
}

/** New password for another user's login (reset-password edge function; owner, or admin for non-admins). */
export async function resetPassword(staffId: string, password: string): Promise<void> {
  const { data, error } = await supabase.functions.invoke<{ ok: true } | { error: string }>('reset-password', {
    body: { staff_id: staffId, password },
  });
  if (error) throw error;
  if (!data || 'error' in data) throw new Error(data?.error ?? 'reset-password returned nothing');
}

// ------------------------------------------------------------------
// Owner control (db/17_owner.sql): branding, print templates, backup, audit
// ------------------------------------------------------------------

/** Logo or signature image into the public `branding` bucket; returns its URL. */
export async function uploadBranding(kind: 'logo' | 'signature', file: File): Promise<string> {
  const org = await currentOrgId();
  const ext = (file.name.split('.').pop() ?? 'png').toLowerCase();
  const path = `${org}/${kind}-${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from('branding').upload(path, file, { contentType: file.type || undefined, upsert: false });
  if (error) throw error;
  return supabase.storage.from('branding').getPublicUrl(path).data.publicUrl;
}

export type PrintTemplate = Tables['print_templates']['Row'];
export type PrintDocType = 'invoice' | 'quotation' | 'challan';
export const PRINT_DOC_TYPES: { key: PrintDocType; label: string }[] = [
  { key: 'invoice', label: 'Invoice' },
  { key: 'quotation', label: 'Quotation' },
  { key: 'challan', label: 'Delivery challan' },
];
export const PAPERS = [
  { key: 'A4', label: 'A4 (210 × 297 mm)' },
  { key: 'A5', label: 'A5 (148 × 210 mm)' },
  { key: 'thermal_80', label: 'Thermal roll 80 mm' },
  { key: 'thermal_58', label: 'Thermal roll 58 mm' },
] as const;
/** Every block a print can show or hide. Default is on; the designer stores explicit false. */
export const PRINT_BLOCKS: { key: string; label: string; group: 'header' | 'columns' | 'footer'; money?: boolean }[] = [
  { key: 'logo', label: 'Logo', group: 'header' },
  { key: 'tagline', label: 'Tagline', group: 'header' },
  { key: 'address', label: 'Address & phone', group: 'header' },
  { key: 'fssai', label: 'FSSAI number', group: 'header' },
  { key: 'email', label: 'Email', group: 'header' },
  { key: 'phones', label: 'Customer phones', group: 'header' },
  { key: 'transport', label: 'Transport / L.R block', group: 'header' },
  { key: 'code', label: 'CODE column', group: 'columns' },
  { key: 'jars', label: 'Jars column', group: 'columns' },
  { key: 'qty', label: 'Qty column', group: 'columns' },
  { key: 'rate', label: 'Rate column', group: 'columns', money: true },
  { key: 'amount', label: 'Amount column', group: 'columns', money: true },
  { key: 'words', label: 'Amount in words', group: 'footer', money: true },
  { key: 'charges', label: 'Discount / freight / round-off lines', group: 'footer', money: true },
  { key: 'bank', label: 'Bank details', group: 'footer' },
  { key: 'terms', label: 'Numbered terms', group: 'footer' },
  { key: 'signature', label: 'Signature image', group: 'footer' },
  { key: 'thanks', label: '"Thanking you" line', group: 'footer' },
];

export async function getPrintTemplate(docType: string): Promise<PrintTemplate | null> {
  const { data, error } = await supabase.from('print_templates').select('*').eq('doc_type', docType).eq('is_default', true).maybeSingle();
  if (error) throw error;
  return data;
}

export type PrintTemplateInput = {
  doc_type: string;
  paper: string;
  show_fields: Record<string, boolean>;
  terms: string[];
  header_html: string | null;
  footer_html: string | null;
};
export async function savePrintTemplate(p: PrintTemplateInput): Promise<string> {
  const { data, error } = await supabase.rpc('save_print_template', { p: { ...p } });
  if (error) throw error;
  return data;
}

export type BackupSettings = Tables['backup_settings']['Row'];
export type BackupRow = Database['public']['Views']['v_backups']['Row'];

export async function getBackupSettings(): Promise<BackupSettings> {
  const { data, error } = await supabase.rpc('get_backup_settings');
  if (error) throw error;
  return data;
}
export async function saveBackupSettings(patch: Tables['backup_settings']['Update']): Promise<void> {
  const org_id = await currentOrgId();
  await expectOk(supabase.from('backup_settings').update(patch).eq('org_id', org_id));
}
export function listBackups(): Promise<BackupRow[]> {
  return expectRows(supabase.from('v_backups').select('*').order('created_at', { ascending: false }).limit(200));
}
export type BackupResult = { backup_id?: string; file_path?: string; size_bytes?: number; pruned?: number; error?: string };
export async function runBackupNow(): Promise<BackupResult> {
  const { data, error } = await supabase.functions.invoke<BackupResult>('backup-org', { body: {} });
  if (error) throw error;
  if (!data) throw new Error('backup-org returned nothing');
  if (data.error) throw new Error(data.error);
  return data;
}
/** Five-minute signed link to the private backup file. */
export async function backupDownloadUrl(filePath: string): Promise<string> {
  const { data, error } = await supabase.storage.from('backups').createSignedUrl(filePath, 300);
  if (error) throw error;
  return data.signedUrl;
}
export type RestoreResult = { org_id: string; restored: Record<string, number>; taken_at: string | null };
export async function restoreBackup(backupId: string): Promise<RestoreResult> {
  const { data, error } = await supabase.functions.invoke<RestoreResult | { error: string }>('restore-backup', { body: { backup_id: backupId } });
  if (error) throw error;
  if (!data || 'error' in data) throw new Error(data?.error ?? 'restore-backup returned nothing');
  return data;
}

export type AuditRow = Database['public']['Functions']['audit_search']['Returns'][number];
export type AuditFilters = { from?: string; to?: string; table?: string; actor?: string; action?: string; search?: string; limit?: number };
export async function searchAudit(f: AuditFilters): Promise<AuditRow[]> {
  const { data, error } = await supabase.rpc('audit_search', {
    ...(f.from ? { p_from: `${f.from}T00:00:00` } : {}),
    ...(f.to ? { p_to: `${f.to}T23:59:59` } : {}),
    ...(f.table ? { p_table: f.table } : {}),
    ...(f.actor ? { p_actor: f.actor } : {}),
    ...(f.action ? { p_action: f.action } : {}),
    ...(f.search ? { p_search: f.search } : {}),
    p_limit: f.limit ?? 200,
  });
  if (error) throw error;
  return data ?? [];
}
/** Audited tables, in the words the owner uses. */
export const AUDIT_TABLES: { key: string; label: string }[] = [
  { key: 'orgs', label: 'Business profile' },
  { key: 'staff', label: 'Users' },
  { key: 'role_permissions', label: 'Permissions' },
  { key: 'customers', label: 'Customers' },
  { key: 'items', label: 'Items' },
  { key: 'item_price_overrides', label: 'Customer rates' },
  { key: 'suppliers', label: 'Suppliers' },
  { key: 'vehicles', label: 'Vehicles' },
  { key: 'price_lists', label: 'Price lists' },
  { key: 'discount_schemes', label: 'Discount schemes' },
  { key: 'invoices', label: 'Invoices' },
  { key: 'quotations', label: 'Quotations' },
  { key: 'orders', label: 'Orders' },
  { key: 'delivery_challans', label: 'Challans' },
  { key: 'purchases', label: 'Purchases' },
  { key: 'purchase_returns', label: 'Purchase returns' },
  { key: 'sales_returns', label: 'Sales returns' },
  { key: 'receipts', label: 'Receipts' },
  { key: 'payments', label: 'Payments' },
  { key: 'cheques', label: 'Cheques' },
  { key: 'cash_bank_accounts', label: 'Cash & bank accounts' },
  { key: 'ledger_accounts', label: 'Ledger accounts' },
  { key: 'account_transfers', label: 'Transfers' },
  { key: 'stock_transfers', label: 'Stock transfers' },
  { key: 'stock_counts', label: 'Stock counts' },
  { key: 'production_batches', label: 'Production batches' },
  { key: 'recipes', label: 'Recipes' },
  { key: 'number_series', label: 'Numbering' },
  { key: 'receipt_modes', label: 'Receipt modes' },
  { key: 'uoms', label: 'Units' },
  { key: 'pack_types', label: 'Pack types' },
  { key: 'expense_heads', label: 'Expense heads' },
  { key: 'sections', label: 'Sections' },
  { key: 'stock_locations', label: 'Locations' },
  { key: 'routes', label: 'Routes' },
  { key: 'message_templates', label: 'Message templates' },
  { key: 'reminder_rules', label: 'Reminder rules' },
  { key: 'transaction_message_settings', label: 'Document messages' },
  { key: 'print_templates', label: 'Print templates' },
  { key: 'backup_settings', label: 'Backup settings' },
];
export function auditTableLabel(key: string | null): string {
  return AUDIT_TABLES.find((t) => t.key === key)?.label ?? key ?? '';
}

// ------------------------------------------------------------------
// Data import (db/07_import.sql)
// ------------------------------------------------------------------
export interface ImportErrorRow {
  row: number;
  error: string;
  data: Record<string, string>;
}

export interface ImportResult {
  target: string;
  dry_run: boolean;
  total: number;
  ok: number;
  unchanged: number;
  errors: number;
  error_rows: ImportErrorRow[];
}

/** A type alias, not an interface, so it is assignable to the RPC's Json parameter. */
export type ImportOptions = {
  location_id?: string;
  txn_date?: string;
};

function asRecord(v: unknown): Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

function num(v: unknown): number {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** Validate (dry run) or commit rows server-side. Every row is reported; bad rows never block good ones. */
export async function runImport(
  target: string,
  rows: Record<string, string>[],
  options: ImportOptions,
  dryRun: boolean,
): Promise<ImportResult> {
  const { data, error } = await supabase.rpc('import_rows', {
    p_target: target,
    p_rows: rows,
    p_options: options,
    p_dry_run: dryRun,
  });
  if (error) throw error;
  const r = asRecord(data);
  const errorRows = Array.isArray(r.error_rows) ? r.error_rows : [];
  return {
    target: String(r.target ?? target),
    dry_run: Boolean(r.dry_run),
    total: num(r.total),
    ok: num(r.ok),
    unchanged: num(r.unchanged),
    errors: num(r.errors),
    error_rows: errorRows.map((e) => {
      const er = asRecord(e);
      const dataRec = asRecord(er.data);
      const cleaned: Record<string, string> = {};
      for (const [k, v] of Object.entries(dataRec)) cleaned[k] = v === null || v === undefined ? '' : String(v);
      return { row: num(er.row), error: String(er.error ?? ''), data: cleaned };
    }),
  };
}

export type ImportJob = Tables['import_jobs']['Row'];

export function listImportJobs(): Promise<ImportJob[]> {
  return expectRows(supabase.from('import_jobs').select('*').order('created_at', { ascending: false }).limit(50));
}

// ------------------------------------------------------------------
// Role permissions
// ------------------------------------------------------------------
export type RolePermission = Tables['role_permissions']['Row'];

export function listRolePermissions(): Promise<RolePermission[]> {
  return expectRows(supabase.from('role_permissions').select('*'));
}

export interface PermissionCell {
  role: StaffRole;
  module: string;
  can_view: boolean;
  can_edit: boolean;
  can_delete: boolean;
}

export async function saveRolePermissions(cells: PermissionCell[]): Promise<void> {
  const orgId = await currentOrgId();
  await expectOk(
    supabase.from('role_permissions').upsert(
      cells.map((c) => ({ ...c, org_id: orgId })),
      { onConflict: 'org_id,role,module' },
    ),
  );
}

/** Wipe and re-seed the matrix from db/06_setup.sql defaults. Owner only (delete on setup). */
export async function resetRolePermissions(): Promise<void> {
  const orgId = await currentOrgId();
  await expectOk(supabase.from('role_permissions').delete().eq('org_id', orgId));
  const { error } = await supabase.rpc('seed_role_permissions', { p_org: orgId });
  if (error) throw error;
}
