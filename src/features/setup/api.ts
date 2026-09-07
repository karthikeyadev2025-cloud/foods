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
