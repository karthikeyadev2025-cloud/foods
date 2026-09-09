import { expectOne, expectRows, queuedRpc, supabase } from '@/lib/supabase';
import { rangeFor, type Page, type PageQuery } from '@/lib/paging';
import { orIlike } from '@/lib/search';
import type { Database } from '@/types/supabase';

type Views = Database['public']['Views'];
export type InvoiceRow = Views['v_invoice_list']['Row'];
export type InvoiceLineRow = Views['v_invoice_lines']['Row'];
export type InvoiceBalanceRow = Views['v_invoice_balance']['Row'];
export type InvoiceStatus = Database['public']['Enums']['invoice_status'];

export const INVOICE_STATUSES: { value: InvoiceStatus; label: string }[] = [
  { value: 'draft', label: 'Draft' },
  { value: 'confirmed', label: 'Confirmed' },
  { value: 'dispatched', label: 'Dispatched' },
  { value: 'delivered', label: 'Delivered' },
  { value: 'cancelled', label: 'Cancelled' },
];

export interface InvoiceListQuery extends PageQuery {
  status?: InvoiceStatus | '';
  from?: string;
  to?: string;
  customerId?: string;
}

function applyFilters(q: InvoiceListQuery) {
  let query = supabase.from('v_invoice_list').select('*', { count: 'exact' });
  query = orIlike(query, ['invoice_no', 'customer_name', 'customer_town'], q.search);
  if (q.status) query = query.eq('status', q.status);
  if (q.from) query = query.gte('invoice_date', q.from);
  if (q.to) query = query.lte('invoice_date', q.to);
  if (q.customerId) query = query.eq('customer_id', q.customerId);
  return query.order('invoice_date', { ascending: false }).order('invoice_no', { ascending: false });
}

export async function listInvoices(q: InvoiceListQuery): Promise<Page<InvoiceRow>> {
  const [from, to] = rangeFor(q.page, q.pageSize);
  const { data, error, count } = await applyFilters(q).range(from, to);
  if (error) throw error;
  return { rows: data ?? [], total: count ?? 0, page: q.page, pageSize: q.pageSize };
}

export function listAllInvoices(q: Omit<InvoiceListQuery, 'page' | 'pageSize'>): Promise<InvoiceRow[]> {
  return expectRows(applyFilters({ ...q, page: 1, pageSize: 10000 }).range(0, 9999));
}

export function getInvoice(id: string): Promise<InvoiceRow> {
  return expectOne(supabase.from('v_invoice_list').select('*').eq('id', id).single());
}

export function getInvoiceLines(id: string): Promise<InvoiceLineRow[]> {
  return expectRows(supabase.from('v_invoice_lines').select('*').eq('invoice_id', id).order('id'));
}

/** Open (unpaid) invoices of a customer, oldest first — what a receipt allocates against. */
export function listOpenInvoices(customerId: string): Promise<InvoiceBalanceRow[]> {
  return expectRows(
    supabase
      .from('v_invoice_balance')
      .select('*')
      .eq('customer_id', customerId)
      .in('status', ['confirmed', 'dispatched', 'delivered'])
      .gt('balance', 0)
      .order('invoice_date')
      .order('invoice_no'),
  );
}

export interface InvoiceHeaderInput {
  id?: string;
  customer_id: string;
  invoice_date: string;
  location_id: string;
  vehicle_id?: string | null;
  /** Selling from a van on a trip: the DB fixes vehicle and location from the trip. */
  trip_id?: string | null;
  transport_name?: string | null;
  lr_no?: string | null;
  lr_date?: string | null;
  freight: number;
  discount: number;
  round_off: number;
  notes?: string | null;
}

export interface InvoiceLineInput {
  item_id: string;
  boxes: number;
  /** Rate per unit. Omit to take the customer's effective rate. */
  rate?: number | null;
}

/** Save a draft (create or replace lines). Numbering, packing snapshot and totals happen in the DB. */
export function saveInvoice(header: InvoiceHeaderInput, lines: InvoiceLineInput[]): Promise<string> {
  return queuedRpc('save_invoice', { p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) }, header.id ? 'Invoice changes' : 'New invoice');
}

export async function setInvoiceStatus(id: string, status: InvoiceStatus): Promise<void> {
  const { error } = await supabase.rpc('set_invoice_status', { p_invoice: id, p_status: status });
  if (error) throw error;
}

/** Vehicle is assigned after the invoice exists, at any status. */
export async function assignVehicle(id: string, vehicleId: string | null): Promise<void> {
  const { error } = await supabase.from('invoices').update({ vehicle_id: vehicleId }).eq('id', id);
  if (error) throw error;
}
