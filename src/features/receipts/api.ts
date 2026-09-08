import { expectOne, expectRows, queuedRpc, supabase } from '@/lib/supabase';
import { rangeFor, sanitizeSearch, type Page, type PageQuery } from '@/lib/paging';
import type { Database } from '@/types/supabase';

type Views = Database['public']['Views'];
export type ReceiptRow = Views['v_receipt_list']['Row'];
export type ReceiptLineRow = Views['v_receipt_lines']['Row'];
export type ReceiptAllocationRow = Views['v_receipt_allocations']['Row'];

export interface ReceiptListQuery extends PageQuery {
  from?: string;
  to?: string;
}

function applyFilters(q: ReceiptListQuery) {
  let query = supabase.from('v_receipt_list').select('*', { count: 'exact' });
  const s = sanitizeSearch(q.search);
  if (s) query = query.or(`receipt_no.ilike.%${s}%,customer_name.ilike.%${s}%,customer_town.ilike.%${s}%`);
  if (q.from) query = query.gte('receipt_date', q.from);
  if (q.to) query = query.lte('receipt_date', q.to);
  return query.order('receipt_date', { ascending: false }).order('receipt_no', { ascending: false });
}

export async function listReceipts(q: ReceiptListQuery): Promise<Page<ReceiptRow>> {
  const [from, to] = rangeFor(q.page, q.pageSize);
  const { data, error, count } = await applyFilters(q).range(from, to);
  if (error) throw error;
  return { rows: data ?? [], total: count ?? 0, page: q.page, pageSize: q.pageSize };
}

export function listAllReceipts(q: Omit<ReceiptListQuery, 'page' | 'pageSize'>): Promise<ReceiptRow[]> {
  return expectRows(applyFilters({ ...q, page: 1, pageSize: 10000 }).range(0, 9999));
}

export function getReceipt(id: string): Promise<ReceiptRow> {
  return expectOne(supabase.from('v_receipt_list').select('*').eq('id', id).single());
}
export function getReceiptLines(id: string): Promise<ReceiptLineRow[]> {
  return expectRows(supabase.from('v_receipt_lines').select('*').eq('receipt_id', id));
}
export function getReceiptAllocations(id: string): Promise<ReceiptAllocationRow[]> {
  return expectRows(supabase.from('v_receipt_allocations').select('*').eq('receipt_id', id).order('invoice_date'));
}

export interface ReceiptHeaderInput {
  customer_id: string;
  receipt_date: string;
  narration: string | null;
  vehicle_id?: string | null;
}
export interface ReceiptLineInput {
  mode_id: string;
  amount: number;
  /** Cheque number for a cheque mode, UTR / slip otherwise. */
  reference: string | null;
  cheque_date?: string | null;
  bank_name?: string | null;
}
export interface AllocationInput {
  invoice_id: string;
  amount: number;
}

/** Empty allocations = FIFO over the customer's open invoices. */
export function saveReceipt(header: ReceiptHeaderInput, lines: ReceiptLineInput[], allocations: AllocationInput[]): Promise<string> {
  return queuedRpc(
    'save_receipt',
    { p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })), p_allocations: allocations.map((a) => ({ ...a })) },
    'Receipt',
  );
}
