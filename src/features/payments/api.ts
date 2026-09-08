import { expectRows, queuedRpc, supabase } from '@/lib/supabase';
import { rangeFor, sanitizeSearch, type Page, type PageQuery } from '@/lib/paging';
import type { Database } from '@/types/supabase';

export type PaymentRow = Database['public']['Views']['v_payment_list']['Row'];

export interface PaymentListQuery extends PageQuery {
  from?: string;
  to?: string;
  kind?: 'supplier' | 'staff' | 'expense' | '';
}

function applyFilters(q: PaymentListQuery) {
  let query = supabase.from('v_payment_list').select('*', { count: 'exact' });
  const s = sanitizeSearch(q.search);
  if (s) query = query.or(`payment_no.ilike.%${s}%,party_name.ilike.%${s}%,narration.ilike.%${s}%`);
  if (q.kind) query = query.eq('party_kind', q.kind);
  if (q.from) query = query.gte('payment_date', q.from);
  if (q.to) query = query.lte('payment_date', q.to);
  return query.order('payment_date', { ascending: false }).order('payment_no', { ascending: false });
}

export async function listPayments(q: PaymentListQuery): Promise<Page<PaymentRow>> {
  const [from, to] = rangeFor(q.page, q.pageSize);
  const { data, error, count } = await applyFilters(q).range(from, to);
  if (error) throw error;
  return { rows: data ?? [], total: count ?? 0, page: q.page, pageSize: q.pageSize };
}

export function listAllPayments(q: Omit<PaymentListQuery, 'page' | 'pageSize'>): Promise<PaymentRow[]> {
  return expectRows(applyFilters({ ...q, page: 1, pageSize: 10000 }).range(0, 9999));
}

export interface PaymentInput {
  supplier_id?: string | null;
  staff_id?: string | null;
  expense_head_id?: string | null;
  payment_date: string;
  mode_id: string;
  amount: number;
  reference: string | null;
  narration: string | null;
  cheque_date?: string | null;
  bank_name?: string | null;
}

export function savePayment(input: PaymentInput): Promise<string> {
  return queuedRpc('save_payment', { p: { ...input } }, 'Payment');
}
