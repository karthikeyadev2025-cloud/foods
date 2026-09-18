import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Fn = Database['public']['Functions'];

export type LastRate = Fn['customer_last_rates']['Returns'][number];
export type PastBill = Fn['customer_recent_bills']['Returns'][number];
export type PastBillLine = Fn['invoice_lines_for_reading']['Returns'][number];

/**
 * What this customer actually paid for each product last time, newest first
 * (db/48). Not the price list — the rate that really went on his bill, which is
 * the one he will quote back across the counter.
 */
export async function customerLastRates(customerId: string): Promise<LastRate[]> {
  const { data, error } = await supabase.rpc('customer_last_rates', { p_customer: customerId });
  if (error) throw error;
  return data ?? [];
}

/** His last few bills, newest first. Cancelled ones are shown, marked. */
export async function customerRecentBills(customerId: string, limit = 12): Promise<PastBill[]> {
  const { data, error } = await supabase.rpc('customer_recent_bills', { p_customer: customerId, p_limit: limit });
  if (error) throw error;
  return data ?? [];
}

/** The lines of one past bill, at the rates it was billed at. */
export async function pastBillLines(invoiceId: string): Promise<PastBillLine[]> {
  const { data, error } = await supabase.rpc('invoice_lines_for_reading', { p_invoice: invoiceId });
  if (error) throw error;
  return data ?? [];
}

/** Query keys, so a new bill refreshes the history it is about to add to. */
export const historyKeys = {
  rates: (customerId: string) => ['customers', 'last-rates', customerId] as const,
  bills: (customerId: string) => ['customers', 'past-bills', customerId] as const,
  lines: (invoiceId: string) => ['customers', 'past-bill-lines', invoiceId] as const,
};
