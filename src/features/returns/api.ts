import { expectOne, expectRows, queuedRpc, supabase } from '@/lib/supabase';
import { rangeFor, type Page, type PageQuery } from '@/lib/paging';
import { orIlike } from '@/lib/search';
import type { Database } from '@/types/supabase';

type Views = Database['public']['Views'];
export type ReturnRow = Views['v_return_list']['Row'];
export type ReturnLineRow = Views['v_return_lines']['Row'];
export type ReturnKind = Database['public']['Enums']['return_kind'];

export const RETURN_KINDS: { value: ReturnKind; label: string; money: string; stock: string }[] = [
  { value: 'fresh_return', label: 'Fresh return', money: 'Full credit', stock: 'Comes back saleable' },
  { value: 'damage_return', label: 'Damage / breakage (BRK)', money: 'Breakage % of value', stock: 'Written off' },
  { value: 'rate_difference', label: 'Rate difference', money: 'Qty × (billed − new rate)', stock: 'No stock movement' },
];

export interface ReturnListQuery extends PageQuery {
  kind?: ReturnKind | '';
  from?: string;
  to?: string;
}

function applyFilters(q: ReturnListQuery) {
  let query = supabase.from('v_return_list').select('*', { count: 'exact' });
  query = orIlike(query, ['return_no', 'customer_name', 'invoice_no'], q.search);
  if (q.kind) query = query.eq('kind', q.kind);
  if (q.from) query = query.gte('return_date', q.from);
  if (q.to) query = query.lte('return_date', q.to);
  return query.order('return_date', { ascending: false }).order('return_no', { ascending: false });
}

export async function listReturns(q: ReturnListQuery): Promise<Page<ReturnRow>> {
  const [from, to] = rangeFor(q.page, q.pageSize);
  const { data, error, count } = await applyFilters(q).range(from, to);
  if (error) throw error;
  return { rows: data ?? [], total: count ?? 0, page: q.page, pageSize: q.pageSize };
}

export function listAllReturns(q: Omit<ReturnListQuery, 'page' | 'pageSize'>): Promise<ReturnRow[]> {
  return expectRows(applyFilters({ ...q, page: 1, pageSize: 10000 }).range(0, 9999));
}

export function getReturn(id: string): Promise<ReturnRow> {
  return expectOne(supabase.from('v_return_list').select('*').eq('id', id).single());
}

export function getReturnLines(id: string): Promise<ReturnLineRow[]> {
  return expectRows(supabase.from('v_return_lines').select('*').eq('return_id', id).order('id'));
}

export interface ReturnHeaderInput {
  customer_id: string;
  invoice_id: string | null;
  kind: ReturnKind;
  return_date: string;
  location_id: string | null;
  notes: string | null;
}

export interface ReturnLineInput {
  item_id: string;
  boxes: number;
  rate: number;
  new_rate?: number | null;
}

export function saveSalesReturn(header: ReturnHeaderInput, lines: ReturnLineInput[]): Promise<string> {
  return queuedRpc('save_sales_return', { p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) }, 'Sales return');
}
