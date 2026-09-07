import { currentOrgId } from '@/features/auth/api';
import { expectOne, expectRows, supabase } from '@/lib/supabase';
import { rangeFor, sanitizeSearch, type Page, type PageQuery } from '@/lib/paging';
import type { Database } from '@/types/supabase';

type Tables = Database['public']['Tables'];
export type CustomerRow = Database['public']['Views']['v_customer_list']['Row'];
export type Customer = Tables['customers']['Row'];

export interface CustomerListQuery extends PageQuery {
  routeId?: string;
  includeInactive?: boolean;
}

function applyFilters(q: CustomerListQuery) {
  let query = supabase.from('v_customer_list').select('*', { count: 'exact' });
  const s = sanitizeSearch(q.search);
  if (s) query = query.or(`name.ilike.%${s}%,mobile1.ilike.%${s}%,town.ilike.%${s}%,code.ilike.%${s}%`);
  if (q.routeId) query = query.eq('route_id', q.routeId);
  if (!q.includeInactive) query = query.eq('is_active', true);
  return query.order('town').order('name');
}

export async function listCustomers(q: CustomerListQuery): Promise<Page<CustomerRow>> {
  const [from, to] = rangeFor(q.page, q.pageSize);
  const { data, error, count } = await applyFilters(q).range(from, to);
  if (error) throw error;
  return { rows: data ?? [], total: count ?? 0, page: q.page, pageSize: q.pageSize };
}

export function listAllCustomers(q: Omit<CustomerListQuery, 'page' | 'pageSize'>): Promise<CustomerRow[]> {
  return expectRows(applyFilters({ ...q, page: 1, pageSize: 10000 }).range(0, 9999));
}

/** Duplicate check on mobile 1: returns the existing customer's name, or null. */
export async function findByMobile(mobile1: string, exceptId?: string): Promise<string | null> {
  let query = supabase.from('customers').select('id, name').eq('mobile1', mobile1).limit(1);
  if (exceptId) query = query.neq('id', exceptId);
  const rows = await expectRows(query);
  return rows[0]?.name ?? null;
}

export type CustomerInsert = Omit<Tables['customers']['Insert'], 'org_id'>;
export type CustomerUpdate = Tables['customers']['Update'];

export async function createCustomer(values: CustomerInsert): Promise<Customer> {
  return expectOne(supabase.from('customers').insert({ ...values, org_id: await currentOrgId() }).select('*').single());
}

export function updateCustomer(id: string, values: CustomerUpdate): Promise<Customer> {
  return expectOne(supabase.from('customers').update(values).eq('id', id).select('*').single());
}
