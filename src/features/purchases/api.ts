import { currentOrgId } from '@/features/auth/api';
import { expectOk, expectOne, expectRows, queuedRpc, supabase } from '@/lib/supabase';
import { rangeFor, type Page, type PageQuery } from '@/lib/paging';
import { orIlike } from '@/lib/search';
import type { Database } from '@/types/supabase';

type Tables = Database['public']['Tables'];
type Views = Database['public']['Views'];
export type PurchaseRow = Views['v_purchase_list']['Row'];
export type PurchaseLineRow = Views['v_purchase_lines']['Row'];
export type SupplierRow = Views['v_supplier_list']['Row'];
export type Supplier = Tables['suppliers']['Row'];

export interface PurchaseListQuery extends PageQuery {
  from?: string;
  to?: string;
  supplierId?: string;
}

function applyFilters(q: PurchaseListQuery) {
  let query = supabase.from('v_purchase_list').select('*', { count: 'exact' });
  query = orIlike(query, ['bill_no', 'supplier_name'], q.search);
  if (q.from) query = query.gte('bill_date', q.from);
  if (q.to) query = query.lte('bill_date', q.to);
  if (q.supplierId) query = query.eq('supplier_id', q.supplierId);
  return query.order('bill_date', { ascending: false }).order('created_at', { ascending: false });
}

export async function listPurchases(q: PurchaseListQuery): Promise<Page<PurchaseRow>> {
  const [from, to] = rangeFor(q.page, q.pageSize);
  const { data, error, count } = await applyFilters(q).range(from, to);
  if (error) throw error;
  return { rows: data ?? [], total: count ?? 0, page: q.page, pageSize: q.pageSize };
}

export function listAllPurchases(q: Omit<PurchaseListQuery, 'page' | 'pageSize'>): Promise<PurchaseRow[]> {
  return expectRows(applyFilters({ ...q, page: 1, pageSize: 10000 }).range(0, 9999));
}

export function getPurchase(id: string): Promise<PurchaseRow> {
  return expectOne(supabase.from('v_purchase_list').select('*').eq('id', id).single());
}

export function getPurchaseLines(id: string): Promise<PurchaseLineRow[]> {
  return expectRows(supabase.from('v_purchase_lines').select('*').eq('purchase_id', id).order('id'));
}

export interface PurchaseHeaderInput {
  supplier_id: string | null;
  bill_no: string | null;
  bill_date: string;
  location_id: string;
  other_charges: number;
  paid_amount: number;
  notes: string | null;
}

export interface PurchaseLineInput {
  item_id: string;
  qty: number;
  uom_id: string;
  rate: number;
}

/** Saves, posts stock in, and journals Dr Purchases / Cr Creditors (+ any cash paid). Final on save. */
export function savePurchase(header: PurchaseHeaderInput, lines: PurchaseLineInput[]): Promise<string> {
  return queuedRpc('save_purchase', { p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) }, 'Purchase bill');
}

// ------------------------------------------------------------------
// Suppliers (owned by purchases)
// ------------------------------------------------------------------
export function listSuppliers(): Promise<SupplierRow[]> {
  return expectRows(supabase.from('v_supplier_list').select('*').order('name'));
}

export function searchSuppliers(q: string): Promise<SupplierRow[]> {
  const query = orIlike(
    supabase.from('v_supplier_list').select('*').eq('is_active', true),
    ['name', 'town', 'mobile1'],
    q,
  );
  return expectRows(query.order('name').limit(15));
}

export type SupplierInsert = Omit<Tables['suppliers']['Insert'], 'org_id'>;

export async function createSupplier(values: SupplierInsert): Promise<Supplier> {
  return expectOne(supabase.from('suppliers').insert({ ...values, org_id: await currentOrgId() }).select('*').single());
}

export function updateSupplier(id: string, values: Tables['suppliers']['Update']): Promise<Supplier> {
  return expectOne(supabase.from('suppliers').update(values).eq('id', id).select('*').single());
}

export function removeSupplier(id: string): Promise<void> {
  return expectOk(supabase.from('suppliers').delete().eq('id', id));
}
