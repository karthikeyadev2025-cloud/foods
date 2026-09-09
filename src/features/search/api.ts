import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

export type DocumentHit = Database['public']['Functions']['search_documents']['Returns'][number];
export type DocumentKind = DocumentHit['kind'];

/**
 * One search across every kind of bill, by number, party or town.
 *
 * The function is security invoker, so a caller sees exactly the documents
 * their role and plan let them open — a hit is never something the link would
 * then refuse.
 */
export async function searchDocuments(term: string, limit = 20): Promise<DocumentHit[]> {
  if (!term.trim()) return [];
  const { data, error } = await supabase.rpc('search_documents', { p_term: term, p_limit: limit });
  if (error) throw error;
  return data ?? [];
}

/** What each kind is called on screen, and where its link goes. */
export const DOC_KINDS: Record<string, { label: string; href: (id: string) => string }> = {
  invoice: { label: 'Invoice', href: (id) => `/invoices/${id}` },
  quotation: { label: 'Quotation', href: (id) => `/quotations/${id}` },
  order: { label: 'Order', href: (id) => `/orders/${id}` },
  challan: { label: 'Challan', href: (id) => `/challans/${id}` },
  receipt: { label: 'Receipt', href: (id) => `/receipts/${id}` },
  payment: { label: 'Payment', href: () => '/payments' },
  purchase: { label: 'Purchase', href: (id) => `/purchases/${id}` },
  return: { label: 'Sales return', href: (id) => `/returns/${id}` },
  purchase_return: { label: 'Purchase return', href: () => '/purchases/returns' },
};

export function kindLabel(kind: string | null): string {
  return (kind && DOC_KINDS[kind]?.label) ?? 'Document';
}

export function kindHref(kind: string | null, id: string | null): string {
  const entry = kind ? DOC_KINDS[kind] : undefined;
  return entry ? entry.href(id ?? '') : '/';
}
