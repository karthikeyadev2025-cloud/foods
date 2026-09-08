import { expectRows, supabase } from '@/lib/supabase';
import { toNumber } from '@/lib/format';
import type { Database } from '@/types/supabase';

type Fns = Database['public']['Functions'];
export type ActivityRow = Fns['dashboard_activity']['Returns'][number];
export type InboundOrderRow = Database['public']['Views']['v_inbound_orders']['Row'];

/** `dashboard_summary()` returns jsonb; every key is a SUM/COUNT over the live tables. */
export interface DashboardSummary {
  sales_today: number;
  sales_mtd: number;
  collection_today: number;
  total_outstanding: number;
  invoices_today: number;
  low_stock_items: number;
  negative_stock: number;
  vehicles_out: number;
  batches_open: number;
  pending_orders: number;
  cash_balance: number;
  bank_balance: number;
  cheques_in_hand: number;
  cheques_due: number;
  payables: number;
  expiring_batches: number;
  open_counts: number;
}

export async function dashboardSummary(orgId: string, date: string): Promise<DashboardSummary> {
  const { data, error } = await supabase.rpc('dashboard_summary', { p_org: orgId, p_date: date });
  if (error) throw error;
  const j = (data && typeof data === 'object' && !Array.isArray(data) ? data : {}) as Record<string, unknown>;
  const n = (k: keyof DashboardSummary) => toNumber(j[k] as string | number | null | undefined);
  return {
    sales_today: n('sales_today'),
    sales_mtd: n('sales_mtd'),
    collection_today: n('collection_today'),
    total_outstanding: n('total_outstanding'),
    invoices_today: n('invoices_today'),
    low_stock_items: n('low_stock_items'),
    negative_stock: n('negative_stock'),
    vehicles_out: n('vehicles_out'),
    batches_open: n('batches_open'),
    pending_orders: n('pending_orders'),
    cash_balance: n('cash_balance'),
    bank_balance: n('bank_balance'),
    cheques_in_hand: n('cheques_in_hand'),
    cheques_due: n('cheques_due'),
    payables: n('payables'),
    expiring_batches: n('expiring_batches'),
    open_counts: n('open_counts'),
  };
}

export async function dashboardActivity(orgId: string, date: string): Promise<ActivityRow[]> {
  const { data, error } = await supabase.rpc('dashboard_activity', { p_org: orgId, p_date: date, p_limit: 40 });
  if (error) throw error;
  return data ?? [];
}

export function pendingOrders(): Promise<InboundOrderRow[]> {
  return expectRows(supabase.from('v_inbound_orders').select('*').eq('status', 'new').order('created_at', { ascending: false }).limit(50));
}

/** Where a row in the activity feed opens. */
export function activityLink(row: ActivityRow): string | null {
  if (!row.doc_id) return null;
  switch (row.kind) {
    case 'Invoice': return `/invoices/${row.doc_id}`;
    case 'Receipt': return `/receipts/${row.doc_id}`;
    case 'Return': return `/returns/${row.doc_id}`;
    case 'Purchase': return `/purchases/${row.doc_id}`;
    case 'Payment': return '/payments';
    case 'Batch': return `/production/batches/${row.doc_id}`;
    case 'Trip': return `/vehicles/trips/${row.doc_id}`;
    default: return null;
  }
}
