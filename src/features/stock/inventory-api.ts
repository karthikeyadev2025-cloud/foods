import { expectRows, supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Views = Database['public']['Views'];
type Fns = Database['public']['Functions'];
export type BatchBalanceRow = Fns['batch_balances']['Returns'][number];
export type ExpiryRow = Fns['expiry_report']['Returns'][number];
export type FefoRow = Fns['fefo_suggest']['Returns'][number];
export type BarcodeRow = Views['v_item_barcodes']['Row'];
export type TransferRow = Views['v_stock_transfers']['Row'];
export type TransferLineRow = Views['v_stock_transfer_lines']['Row'];
export type CountRow = Views['v_stock_counts']['Row'];
export type CountLineRow = Views['v_stock_count_lines']['Row'];

// ---------------- batches & expiry ----------------
export async function batchBalances(orgId: string, itemId?: string): Promise<BatchBalanceRow[]> {
  const { data, error } = await supabase.rpc('batch_balances', { p_org: orgId, p_item: itemId || undefined });
  if (error) throw error;
  return data ?? [];
}

export async function expiryReport(orgId: string, days: number): Promise<ExpiryRow[]> {
  const { data, error } = await supabase.rpc('expiry_report', { p_org: orgId, p_days: days });
  if (error) throw error;
  return data ?? [];
}

/** Earliest-expiring batches to pick from when loading N boxes. */
export async function fefoSuggest(itemId: string, boxes: number): Promise<FefoRow[]> {
  const { data, error } = await supabase.rpc('fefo_suggest', { p_item: itemId, p_boxes: boxes });
  if (error) throw error;
  return data ?? [];
}

// ---------------- barcodes ----------------
export function listBarcodes(): Promise<BarcodeRow[]> {
  return expectRows(supabase.from('v_item_barcodes').select('*').order('item_code').order('level'));
}

export async function generateBarcodes(itemId?: string): Promise<number> {
  const { data, error } = await supabase.rpc('generate_barcodes', { p_item: itemId || undefined });
  if (error) throw error;
  return data ?? 0;
}

export async function itemByBarcode(code: string): Promise<{ item_id: string; level: 'box' | 'unit' } | null> {
  const { data, error } = await supabase.rpc('item_by_barcode', { p_code: code });
  if (error) throw error;
  const row = data?.[0];
  return row?.item_id ? { item_id: row.item_id, level: row.level === 'unit' ? 'unit' : 'box' } : null;
}

// ---------------- transfers ----------------
export function listTransfers(): Promise<TransferRow[]> {
  return expectRows(supabase.from('v_stock_transfers').select('*').order('txn_date', { ascending: false }).order('created_at', { ascending: false }).limit(300));
}

export function getTransferLines(id: string): Promise<TransferLineRow[]> {
  return expectRows(supabase.from('v_stock_transfer_lines').select('*').eq('transfer_id', id).order('item_code'));
}

export async function saveStockTransfer(header: { from_location: string; to_location: string; txn_date: string; notes?: string | null }, lines: { item_id: string; boxes: number }[]): Promise<string> {
  const { data, error } = await supabase.rpc('save_stock_transfer', { p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) });
  if (error) throw error;
  return data;
}

// ---------------- physical counts ----------------
export function listCounts(): Promise<CountRow[]> {
  return expectRows(supabase.from('v_stock_counts').select('*').order('count_date', { ascending: false }).order('created_at', { ascending: false }).limit(200));
}

export async function getCount(id: string): Promise<CountRow> {
  const rows = await expectRows(supabase.from('v_stock_counts').select('*').eq('id', id));
  const row = rows[0];
  if (!row) throw new Error('Count not found');
  return row;
}

export function getCountLines(id: string): Promise<CountLineRow[]> {
  return expectRows(supabase.from('v_stock_count_lines').select('*').eq('count_id', id).order('section_sort').order('item_code'));
}

export async function openStockCount(locationId: string, date: string, sectionId?: string, notes?: string): Promise<string> {
  const { data, error } = await supabase.rpc('open_stock_count', { p_location: locationId, p_date: date, p_section: sectionId || undefined, p_notes: notes || undefined });
  if (error) throw error;
  return data;
}

export async function updateStockCount(id: string, lines: { item_id: string; counted_boxes: number | null }[]): Promise<number> {
  const { data, error } = await supabase.rpc('update_stock_count', { p_count: id, p_lines: lines.map((l) => ({ ...l })) });
  if (error) throw error;
  return data ?? 0;
}

export async function postStockCount(id: string): Promise<number> {
  const { data, error } = await supabase.rpc('post_stock_count', { p_count: id });
  if (error) throw error;
  return data ?? 0;
}

export async function cancelStockCount(id: string): Promise<void> {
  const { error } = await supabase.rpc('cancel_stock_count', { p_count: id });
  if (error) throw error;
}
