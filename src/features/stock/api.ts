import { expectRows, supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Fns = Database['public']['Functions'];
export type ClosingStockRow = Fns['closing_stock_report']['Returns'][number];
export type MovementRow = Fns['stock_movements']['Returns'][number];
export type ItemStockRow = Database['public']['Views']['v_item_stock']['Row'];
export type NegativeStockRow = Fns['negative_stock']['Returns'][number];
export type ItemProblemRow = Fns['item_data_problems']['Returns'][number];
export type DuplicateRow = Fns['duplicate_stock_rows']['Returns'][number];

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

// ---------------- data health ----------------

/** Products showing less than nothing, per godown, with the size of the hole. */
export async function negativeStock(): Promise<NegativeStockRow[]> {
  const { data, error } = await supabase.rpc('negative_stock');
  if (error) throw error;
  return data ?? [];
}

/** One row per thing that makes a product unusable or its reports wrong. */
export async function itemProblems(): Promise<ItemProblemRow[]> {
  const { data, error } = await supabase.rpc('item_data_problems');
  if (error) throw error;
  return data ?? [];
}

/** The same movement recorded more than once. */
export async function duplicateStockRows(): Promise<DuplicateRow[]> {
  const { data, error } = await supabase.rpc('duplicate_stock_rows');
  if (error) throw error;
  return data ?? [];
}

/**
 * Counts the extra copies; deletes them only when `apply` is true.
 *
 * Dry run by default on purpose — the number is shown on the button before
 * anyone commits to a delete that cannot be undone.
 */
export async function removeDuplicateStockRows(apply = false): Promise<number> {
  const { data, error } = await supabase.rpc('remove_duplicate_stock_rows', { p_apply: apply });
  if (error) throw error;
  return Number(data ?? 0);
}
