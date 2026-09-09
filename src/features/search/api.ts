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

/**
 * What each kind is called on screen, and where its link goes.
 *
 * The master screens are lists rather than one page per record, so their links
 * carry the name as `?q=`; each list seeds its own search box from it, which
 * lands on the record without needing a detail route that does not exist.
 */
export const DOC_KINDS: Record<string, { label: string; href: (id: string, party: string) => string }> = {
  customer: { label: 'Customer', href: (_id, party) => `/customers?q=${encodeURIComponent(party)}` },
  supplier: { label: 'Supplier', href: (_id, party) => `/purchases/suppliers?q=${encodeURIComponent(party)}` },
  item: { label: 'Product', href: (id) => `/items/${id}` },
  // Setup > Users is a short list with no search box of its own, so the link
  // opens the tab rather than pretending to filter it.
  staff: { label: 'Staff', href: () => '/setup/staff' },
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

export function kindHref(kind: string | null, id: string | null, party: string | null): string {
  const entry = kind ? DOC_KINDS[kind] : undefined;
  return entry ? entry.href(id ?? '', party ?? '') : '/';
}
