import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Fns = Database['public']['Functions'];
export type RegisterRow = Fns['receipts_register']['Returns'][number];
export type LedgerRow = Fns['customer_ledger']['Returns'][number];
export type AgeingRow = Fns['outstanding_ageing']['Returns'][number];
export type ModeRow = Fns['collection_by_mode']['Returns'][number];
export type RouteRow = Fns['route_collection']['Returns'][number];
export type SalesRow = Fns['sales_summary']['Returns'][number];
export type SalesGroup = 'day' | 'month' | 'customer' | 'town' | 'route' | 'item' | 'section';

/** Receipts & payments register — one row per customer with activity or a balance in the period. */
export async function receiptsRegister(orgId: string, from: string, to: string, routeId?: string): Promise<RegisterRow[]> {
  const { data, error } = await supabase.rpc('receipts_register', { p_org: orgId, p_from: from, p_to: to, p_route: routeId || undefined });
  if (error) throw error;
  return data ?? [];
}

export async function customerLedger(customerId: string, from?: string, to?: string): Promise<LedgerRow[]> {
  const { data, error } = await supabase.rpc('customer_ledger', { p_customer: customerId, p_from: from || undefined, p_to: to || undefined });
  if (error) throw error;
  return data ?? [];
}

export async function outstandingAgeing(orgId: string, asOn: string, routeId?: string): Promise<AgeingRow[]> {
  const { data, error } = await supabase.rpc('outstanding_ageing', { p_org: orgId, p_as_on: asOn, p_route: routeId || undefined });
  if (error) throw error;
  return data ?? [];
}

export async function collectionByMode(orgId: string, from: string, to: string, routeId?: string): Promise<ModeRow[]> {
  const { data, error } = await supabase.rpc('collection_by_mode', { p_org: orgId, p_from: from, p_to: to, p_route: routeId || undefined });
  if (error) throw error;
  return data ?? [];
}

export async function routeCollection(orgId: string, from: string, to: string): Promise<RouteRow[]> {
  const { data, error } = await supabase.rpc('route_collection', { p_org: orgId, p_from: from, p_to: to });
  if (error) throw error;
  return data ?? [];
}

export async function salesSummary(orgId: string, from: string, to: string, group: SalesGroup): Promise<SalesRow[]> {
  const { data, error } = await supabase.rpc('sales_summary', { p_org: orgId, p_from: from, p_to: to, p_group: group });
  if (error) throw error;
  return data ?? [];
}
