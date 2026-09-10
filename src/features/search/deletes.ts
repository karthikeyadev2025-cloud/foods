import { supabase } from '@/lib/supabase';

/** The record kinds that can be deleted outright when nothing points at them. */
export type MasterKind = 'item' | 'customer' | 'supplier' | 'staff';

/** The document kinds. Some cancel rather than delete; the result says which. */
export type DocumentDeleteKind =
  | 'invoice' | 'quotation' | 'order' | 'challan'
  | 'receipt' | 'payment' | 'purchase' | 'return' | 'purchase_return';

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
