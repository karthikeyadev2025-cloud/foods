import { supabase } from '@/lib/supabase';

/** The record kinds that can be deleted outright when nothing points at them. */
export type MasterKind = 'item' | 'customer' | 'supplier' | 'staff' | 'vehicle' | 'recipe';

/** The document kinds. Some cancel rather than delete; the result says which. */
export type DocumentDeleteKind =
  | 'invoice' | 'quotation' | 'order' | 'challan'
  | 'receipt' | 'payment' | 'purchase' | 'return' | 'purchase_return'
  // db/47 — the six screens that had no way to remove anything at all.
  | 'stock_transfer' | 'stock_count' | 'trip' | 'journal' | 'cheque'
  // db/49 — the last two.
  | 'batch';

/**
 * Delete a product, customer, supplier or member of staff.
 *
 * Throws with a sentence naming what is in the way when the record is already
 * on a document — that message is written for the person at the screen and is
 * shown to them unchanged.
 */
export async function deleteMaster(kind: MasterKind, id: string): Promise<string> {
  const { data, error } = await supabase.rpc('delete_master', { p_kind: kind, p_id: id });
  if (error) throw error;
  return data ?? 'deleted';
}

/**
 * Undo a document: 'cancelled' when it stays on the list marked cancelled,
 * 'deleted' when it is removed. Either way its stock and ledger come back.
 */
export async function deleteDocument(kind: DocumentDeleteKind, id: string): Promise<string> {
  const { data, error } = await supabase.rpc('delete_document', { p_kind: kind, p_id: id });
  if (error) throw error;
  return data ?? 'deleted';
}

/**
 * Remove a product outright, taking the stock movements nobody billed with it
 * (db/42). Refused the moment any document names it, so this is only ever the
 * answer for something typed or imported by mistake.
 */
export async function purgeItem(id: string): Promise<string> {
  const { data, error } = await supabase.rpc('purge_item', { p_id: id });
  if (error) throw error;
  return String(data ?? 'removed');
}

/**
 * Remove a user (db/43). Refuses your own login and the last owner — both lock
 * the shop out of its own settings with no way back from inside the app.
 */
export async function deleteStaff(id: string): Promise<string> {
  const { data, error } = await supabase.rpc('delete_staff', { p_id: id });
  if (error) throw error;
  return String(data ?? 'deleted');
}
