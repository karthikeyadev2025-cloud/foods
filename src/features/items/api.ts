import { currentOrgId } from '@/features/auth/api';
import { expectOne, expectRows, supabase } from '@/lib/supabase';
import { rangeFor, sanitizeSearch, type Page, type PageQuery } from '@/lib/paging';
import type { Database } from '@/types/supabase';

type Tables = Database['public']['Tables'];
export type ItemRow = Database['public']['Views']['v_item_list']['Row'];
export type Item = Tables['items']['Row'];
export type ItemType = Database['public']['Enums']['item_type'];

export interface ItemListQuery extends PageQuery {
  sectionId?: string;
  packTypeId?: string;
  type?: ItemType | '';
  includeInactive?: boolean;
}

function applyFilters(q: ItemListQuery) {
  let query = supabase.from('v_item_list').select('*', { count: 'exact' });
  const s = sanitizeSearch(q.search);
  if (s) query = query.or(`item_code.ilike.%${s}%,name.ilike.%${s}%`);
  if (q.sectionId) query = query.eq('section_id', q.sectionId);
  if (q.packTypeId) query = query.eq('pack_type_id', q.packTypeId);
  if (q.type) query = query.eq('type', q.type);
  if (!q.includeInactive) query = query.eq('is_active', true);
  return query.order('section_sort').order('item_code');
}

export async function listItems(q: ItemListQuery): Promise<Page<ItemRow>> {
  const [from, to] = rangeFor(q.page, q.pageSize);
  const { data, error, count } = await applyFilters(q).range(from, to);
  if (error) throw error;
  return { rows: data ?? [], total: count ?? 0, page: q.page, pageSize: q.pageSize };
}

/** Every matching row, for Excel export. Capped well above the 200-item master. */
export async function listAllItems(q: Omit<ItemListQuery, 'page' | 'pageSize'>): Promise<ItemRow[]> {
  return expectRows(applyFilters({ ...q, page: 1, pageSize: 5000 }).range(0, 4999));
}

export function getItem(id: string): Promise<ItemRow> {
  return expectOne(supabase.from('v_item_list').select('*').eq('id', id).single());
}

export async function itemCodeExists(code: string, exceptId?: string): Promise<boolean> {
  let query = supabase.from('items').select('id').eq('item_code', code).limit(1);
  if (exceptId) query = query.neq('id', exceptId);
  const rows = await expectRows(query);
  return rows.length > 0;
}

export type ItemInsert = Omit<Tables['items']['Insert'], 'org_id'>;
export type ItemUpdate = Tables['items']['Update'];

export async function createItem(values: ItemInsert): Promise<Item> {
  return expectOne(supabase.from('items').insert({ ...values, org_id: await currentOrgId() }).select('*').single());
}

export function updateItem(id: string, values: ItemUpdate): Promise<Item> {
  return expectOne(supabase.from('items').update(values).eq('id', id).select('*').single());
}
