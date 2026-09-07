import { expectRows, supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Fns = Database['public']['Functions'];
export type ClosingStockRow = Fns['closing_stock_report']['Returns'][number];
export type MovementRow = Fns['stock_movements']['Returns'][number];
export type ItemStockRow = Database['public']['Views']['v_item_stock']['Row'];

export async function closingStock(orgId: string, date: string, locationId?: string, sectionId?: string): Promise<ClosingStockRow[]> {
  const { data, error } = await supabase.rpc('closing_stock_report', {
    p_org: orgId,
    p_date: date,
    p_location: locationId || undefined,
    p_section: sectionId || undefined,
  });
  if (error) throw error;
  return data ?? [];
}

export async function stockMovements(itemId: string, from?: string, to?: string, locationId?: string): Promise<MovementRow[]> {
  const { data, error } = await supabase.rpc('stock_movements', {
    p_item: itemId,
    p_from: from || undefined,
    p_to: to || undefined,
    p_location: locationId || undefined,
  });
  if (error) throw error;
  return data ?? [];
}

export function listItemStock(opts: { lowOnly?: boolean } = {}): Promise<ItemStockRow[]> {
  let query = supabase.from('v_item_stock').select('*');
  if (opts.lowOnly) query = query.eq('is_low', true);
  return expectRows(query.order('section_name').order('item_code'));
}
