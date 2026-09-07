import { expectOne, expectRows, supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Views = Database['public']['Views'];
type Fns = Database['public']['Functions'];
export type RecipeRow = Views['v_recipe_list']['Row'];
export type RecipeIngredientRow = Views['v_recipe_ingredients']['Row'];
export type BatchRow = Views['v_batch_list']['Row'];
export type BatchIngredientRow = Views['v_batch_ingredients']['Row'];
export type BatchStatus = Database['public']['Enums']['batch_status'];
export type VarianceRow = Fns['production_variance']['Returns'][number];
export type VarianceGroup = 'item' | 'mestri' | 'week';

/** Badge tone per batch status, shared by the list and the sheet. */
export const batchTone: Record<BatchStatus, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  open: 'default',
  closed: 'secondary',
  cancelled: 'destructive',
};

// ---------------- recipes ----------------
export function listRecipes(): Promise<RecipeRow[]> {
  return expectRows(supabase.from('v_recipe_list').select('*').order('is_active', { ascending: false }).order('item_code'));
}

export function getRecipeIngredients(recipeId: string): Promise<RecipeIngredientRow[]> {
  return expectRows(supabase.from('v_recipe_ingredients').select('*').eq('recipe_id', recipeId).order('item_code'));
}

export interface RecipeHeaderInput {
  id?: string;
  item_id: string;
  name?: string | null;
  pieces_per_plate: number;
  is_active?: boolean;
}
export interface RecipeIngredientInput {
  ingredient_id: string;
  qty_per_plate: number;
  uom_id?: string | null;
}

export async function saveRecipe(header: RecipeHeaderInput, ingredients: RecipeIngredientInput[]): Promise<string> {
  const { data, error } = await supabase.rpc('save_recipe', { p_header: { ...header }, p_ingredients: ingredients.map((i) => ({ ...i })) });
  if (error) throw error;
  return data;
}

// ---------------- batches ----------------
export function listBatches(opts: { status?: BatchStatus | ''; from?: string; to?: string } = {}): Promise<BatchRow[]> {
  let query = supabase.from('v_batch_list').select('*');
  if (opts.status) query = query.eq('status', opts.status);
  if (opts.from) query = query.gte('production_date', opts.from);
  if (opts.to) query = query.lte('production_date', opts.to);
  return expectRows(query.order('production_date', { ascending: false }).order('batch_no', { ascending: false }).limit(300));
}

export function getBatch(id: string): Promise<BatchRow> {
  return expectOne(supabase.from('v_batch_list').select('*').eq('id', id).single());
}

export function getBatchIngredients(id: string): Promise<BatchIngredientRow[]> {
  return expectRows(supabase.from('v_batch_ingredients').select('*').eq('batch_id', id).order('item_code'));
}

export interface OpenBatchInput {
  item_id: string;
  plates: number;
  production_date: string;
  location_id: string;
  chief_id?: string | null;
  no_of_workers?: number;
  mestry_count?: number;
  labour_count?: number;
  notes?: string | null;
}

export async function openBatch(input: OpenBatchInput): Promise<string> {
  const { data, error } = await supabase.rpc('open_production_batch', { p: { ...input } });
  if (error) throw error;
  return data;
}

export interface ActualsInput {
  actual_boxes?: number;
  no_of_workers?: number;
  mestry_count?: number;
  labour_count?: number;
  labour_cost?: number;
  notes?: string | null;
  lines?: { id: string; actual_qty: number }[];
}

export async function updateBatchActuals(id: string, input: ActualsInput): Promise<void> {
  const { error } = await supabase.rpc('update_batch_actuals', { p_batch: id, p: { ...input, lines: input.lines?.map((l) => ({ ...l })) } });
  if (error) throw error;
}

export async function closeBatch(id: string): Promise<void> {
  const { error } = await supabase.rpc('close_production_batch', { p_batch: id });
  if (error) throw error;
}

export async function cancelBatch(id: string): Promise<void> {
  const { error } = await supabase.rpc('cancel_production_batch', { p_batch: id });
  if (error) throw error;
}

// ---------------- variance ----------------
export async function productionVariance(orgId: string, from: string, to: string, group: VarianceGroup): Promise<VarianceRow[]> {
  const { data, error } = await supabase.rpc('production_variance', { p_org: orgId, p_from: from, p_to: to, p_group: group });
  if (error) throw error;
  return data ?? [];
}
