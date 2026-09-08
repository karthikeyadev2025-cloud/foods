import { currentOrgId } from '@/features/auth/api';
import { expectOk, expectOne, expectRows, supabase } from '@/lib/supabase';
import { rangeFor, sanitizeSearch, type Page, type PageQuery } from '@/lib/paging';
import type { Database } from '@/types/supabase';

type Tables = Database['public']['Tables'];
type Views = Database['public']['Views'];
type Fns = Database['public']['Functions'];

export type DocState = Database['public']['Enums']['doc_state'];
export type OrderKind = Database['public']['Enums']['order_kind'];
export type QuotationRow = Views['v_quotation_list']['Row'];
export type QuotationLineRow = Views['v_quotation_lines']['Row'];
export type OrderRow = Views['v_order_list']['Row'];
export type OrderLineRow = Views['v_order_lines']['Row'];
export type FulfilmentRow = Views['v_order_fulfilments']['Row'];
export type ChallanRow = Views['v_challan_list']['Row'];
export type ChallanLineRow = Views['v_challan_lines']['Row'];
export type PurchaseReturnRow = Views['v_purchase_return_list']['Row'];
export type PurchaseReturnLineRow = Views['v_purchase_return_lines']['Row'];
export type PriceListRow = Views['v_price_lists']['Row'];
export type PriceListRateRow = Fns['price_list_rates']['Returns'][number];
export type DiscountSchemeRow = Views['v_discount_schemes']['Row'];

export const stateTone: Record<DocState, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  open: 'default',
  partial: 'secondary',
  completed: 'secondary',
  converted: 'secondary',
  cancelled: 'destructive',
};

let lineSeq = 0;
/** Stable React key for a grid line. */
export const nextLineKey = () => `d${++lineSeq}`;

/** A line as the operator builds it on any document grid. */
export interface DocLine {
  key: string;
  item_id: string;
  item_code: string;
  item_name: string;
  units_per_box: number;
  boxes: number;
  rate: number;
}

// ---------------- quotations ----------------
export interface DocListQuery extends PageQuery {
  state?: DocState | '';
  from?: string;
  to?: string;
}

function quotationQuery(q: DocListQuery) {
  let query = supabase.from('v_quotation_list').select('*', { count: 'exact' });
  const s = sanitizeSearch(q.search);
  if (s) query = query.or(`quote_no.ilike.%${s}%,customer_name.ilike.%${s}%,customer_town.ilike.%${s}%`);
  if (q.state) query = query.eq('state', q.state);
  if (q.from) query = query.gte('quote_date', q.from);
  if (q.to) query = query.lte('quote_date', q.to);
  return query.order('quote_date', { ascending: false }).order('quote_no', { ascending: false });
}

export async function listQuotations(q: DocListQuery): Promise<Page<QuotationRow>> {
  const [from, to] = rangeFor(q.page, q.pageSize);
  const { data, error, count } = await quotationQuery(q).range(from, to);
  if (error) throw error;
  return { rows: data ?? [], total: count ?? 0, page: q.page, pageSize: q.pageSize };
}

export function listAllQuotations(q: Omit<DocListQuery, 'page' | 'pageSize'>): Promise<QuotationRow[]> {
  return expectRows(quotationQuery({ ...q, page: 1, pageSize: 5000 }).range(0, 4999));
}

export function getQuotation(id: string): Promise<QuotationRow> {
  return expectOne(supabase.from('v_quotation_list').select('*').eq('id', id).single());
}

export function getQuotationLines(id: string): Promise<QuotationLineRow[]> {
  return expectRows(supabase.from('v_quotation_lines').select('*').eq('quotation_id', id).order('id'));
}

export type QuotationHeaderInput = {
  id?: string;
  customer_id: string;
  quote_date: string;
  valid_till?: string | null;
  transport_name?: string | null;
  lr_no?: string | null;
  lr_date?: string | null;
  freight: number;
  discount: number;
  round_off: number;
  notes?: string | null;
};
export type LineInput = { item_id: string; boxes: number; rate?: number | null };

export async function saveQuotation(header: QuotationHeaderInput, lines: LineInput[]): Promise<string> {
  const { data, error } = await supabase.rpc('save_quotation', { p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) });
  if (error) throw error;
  return data;
}

export async function setQuotationState(id: string, state: 'open' | 'cancelled'): Promise<void> {
  const { error } = await supabase.rpc('set_quotation_state', { p_quote: id, p_state: state });
  if (error) throw error;
}

export async function convertQuotation(id: string, locationId: string, invoiceDate: string): Promise<string> {
  const { data, error } = await supabase.rpc('convert_quotation', { p_quote: id, p_location: locationId, p_invoice_date: invoiceDate });
  if (error) throw error;
  return data;
}

// ---------------- orders ----------------
export function listOrders(opts: { kind: OrderKind; state?: DocState | ''; search?: string }): Promise<OrderRow[]> {
  let query = supabase.from('v_order_list').select('*').eq('kind', opts.kind);
  if (opts.state) query = query.eq('state', opts.state);
  const s = sanitizeSearch(opts.search);
  if (s) query = query.or(`order_no.ilike.%${s}%,party_name.ilike.%${s}%`);
  return expectRows(query.order('order_date', { ascending: false }).order('created_at', { ascending: false }).limit(300));
}

export function getOrder(id: string): Promise<OrderRow> {
  return expectOne(supabase.from('v_order_list').select('*').eq('id', id).single());
}

export function getOrderLines(id: string): Promise<OrderLineRow[]> {
  return expectRows(supabase.from('v_order_lines').select('*').eq('order_id', id).order('id'));
}

export function getOrderFulfilments(id: string): Promise<FulfilmentRow[]> {
  return expectRows(supabase.from('v_order_fulfilments').select('*').eq('order_id', id).order('created_at'));
}

export type OrderHeaderInput = {
  id?: string;
  kind: OrderKind;
  customer_id?: string | null;
  supplier_id?: string | null;
  order_date: string;
  due_date?: string | null;
  advance: number;
  notes?: string | null;
  source_inbound_id?: string | null;
};

export async function saveOrder(header: OrderHeaderInput, lines: LineInput[]): Promise<string> {
  const { data, error } = await supabase.rpc('save_order', { p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) });
  if (error) throw error;
  return data;
}

export async function cancelOrder(id: string): Promise<void> {
  const { error } = await supabase.rpc('cancel_order', { p_order: id });
  if (error) throw error;
}

export type FulfilExtra = { location_id: string; doc_date: string; bill_no?: string | null; paid_amount?: number; transport_name?: string | null; lr_no?: string | null; freight?: number };

/** Lines null = everything still pending. Returns the invoice or purchase id created. */
export async function fulfilOrder(id: string, lines: { item_id: string; boxes: number }[] | null, extra: FulfilExtra): Promise<string> {
  const { data, error } = await supabase.rpc('fulfil_order', { p_order: id, p_lines: lines ? lines.map((l) => ({ ...l })) : undefined, p_extra: { ...extra } });
  if (error) throw error;
  return data;
}

export async function convertInboundToOrder(inboundId: string, header: { customer_id: string; due_date?: string | null; notes?: string | null }, lines: LineInput[]): Promise<string> {
  const { data, error } = await supabase.rpc('convert_inbound_to_order', { p_inbound: inboundId, p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) });
  if (error) throw error;
  return data;
}

// ---------------- challans ----------------
export function listChallans(opts: { state?: DocState | ''; search?: string } = {}): Promise<ChallanRow[]> {
  let query = supabase.from('v_challan_list').select('*');
  if (opts.state) query = query.eq('state', opts.state);
  const s = sanitizeSearch(opts.search);
  if (s) query = query.or(`challan_no.ilike.%${s}%,customer_name.ilike.%${s}%,customer_town.ilike.%${s}%`);
  return expectRows(query.order('challan_date', { ascending: false }).order('created_at', { ascending: false }).limit(300));
}

export function getChallan(id: string): Promise<ChallanRow> {
  return expectOne(supabase.from('v_challan_list').select('*').eq('id', id).single());
}

export function getChallanLines(id: string): Promise<ChallanLineRow[]> {
  return expectRows(supabase.from('v_challan_lines').select('*').eq('challan_id', id).order('id'));
}

export type ChallanHeaderInput = { id?: string; customer_id: string; challan_date: string; location_id: string; vehicle_id?: string | null; notes?: string | null };

export async function saveChallan(header: ChallanHeaderInput, lines: { item_id: string; boxes: number }[]): Promise<string> {
  const { data, error } = await supabase.rpc('save_challan', { p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) });
  if (error) throw error;
  return data;
}

export async function cancelChallan(id: string): Promise<void> {
  const { error } = await supabase.rpc('cancel_challan', { p_challan: id });
  if (error) throw error;
}

export async function convertChallan(id: string, extra: { invoice_date: string; transport_name?: string | null; lr_no?: string | null; freight?: number; rates?: { item_id: string; rate: number }[] }): Promise<string> {
  const { data, error } = await supabase.rpc('convert_challan', { p_challan: id, p_extra: { ...extra, rates: extra.rates?.map((r) => ({ ...r })) } });
  if (error) throw error;
  return data;
}

// ---------------- purchase returns ----------------
export function listPurchaseReturns(search?: string): Promise<PurchaseReturnRow[]> {
  let query = supabase.from('v_purchase_return_list').select('*');
  const s = sanitizeSearch(search);
  if (s) query = query.or(`return_no.ilike.%${s}%,supplier_name.ilike.%${s}%,bill_no.ilike.%${s}%`);
  return expectRows(query.order('return_date', { ascending: false }).order('created_at', { ascending: false }).limit(300));
}

export function getPurchaseReturnLines(id: string): Promise<PurchaseReturnLineRow[]> {
  return expectRows(supabase.from('v_purchase_return_lines').select('*').eq('return_id', id).order('id'));
}

export type PurchaseReturnHeaderInput = { supplier_id: string; purchase_id?: string | null; return_date: string; location_id: string; notes?: string | null };
export type PurchaseReturnLineInput = { item_id: string; qty: number; uom_id?: string | null; rate: number };

export async function savePurchaseReturn(header: PurchaseReturnHeaderInput, lines: PurchaseReturnLineInput[]): Promise<string> {
  const { data, error } = await supabase.rpc('save_purchase_return', { p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) });
  if (error) throw error;
  return data;
}

// ---------------- price lists ----------------
export function listPriceLists(): Promise<PriceListRow[]> {
  return expectRows(supabase.from('v_price_lists').select('*').order('is_default', { ascending: false }).order('name'));
}

export const priceListsApi = {
  create: async (v: Omit<Tables['price_lists']['Insert'], 'org_id'>) =>
    expectOne(supabase.from('price_lists').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id: string, v: Tables['price_lists']['Update']) =>
    expectOne(supabase.from('price_lists').update({ ...v, updated_at: new Date().toISOString() }).eq('id', id).select('*').single()),
  remove: (id: string) => expectOk(supabase.from('price_lists').delete().eq('id', id)),
};

export async function priceListRates(listId: string): Promise<PriceListRateRow[]> {
  const { data, error } = await supabase.rpc('price_list_rates', { p_list: listId });
  if (error) throw error;
  return data ?? [];
}

export async function setPriceListRate(listId: string, itemId: string, rate: number | null): Promise<void> {
  // null clears the rate; the generated type only knows the numeric parameter
  const { error } = await supabase.rpc('set_price_list_rate', { p_list: listId, p_item: itemId, p_rate: rate as unknown as number });
  if (error) throw error;
}

export type BulkMode = 'pct' | 'add' | 'copy_master' | 'copy_list';

export async function bulkUpdatePriceList(listId: string, mode: BulkMode, value: number, sectionId?: string, sourceListId?: string): Promise<number> {
  const { data, error } = await supabase.rpc('bulk_update_price_list', { p_list: listId, p_mode: mode, p_value: value, p_section: sectionId || undefined, p_source_list: sourceListId || undefined });
  if (error) throw error;
  return data ?? 0;
}

export async function assignPriceList(listId: string | null, routeId?: string, town?: string): Promise<number> {
  // null takes the customers off every list
  const { data, error } = await supabase.rpc('assign_price_list', { p_list: listId as unknown as string, p_route: routeId || undefined, p_town: town || undefined });
  if (error) throw error;
  return data ?? 0;
}

// ---------------- discount schemes ----------------
export function listDiscountSchemes(): Promise<DiscountSchemeRow[]> {
  return expectRows(supabase.from('v_discount_schemes').select('*').order('is_active', { ascending: false }).order('name'));
}

export const discountSchemesApi = {
  create: async (v: Omit<Tables['discount_schemes']['Insert'], 'org_id'>) =>
    expectOne(supabase.from('discount_schemes').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id: string, v: Tables['discount_schemes']['Update']) =>
    expectOne(supabase.from('discount_schemes').update(v).eq('id', id).select('*').single()),
  remove: (id: string) => expectOk(supabase.from('discount_schemes').delete().eq('id', id)),
};

export async function applyDiscountSchemes(invoiceId: string): Promise<{ discount: number; free_lines: { item_id: string; boxes: number; scheme: string }[] }> {
  const { data, error } = await supabase.rpc('apply_discount_schemes', { p_invoice: invoiceId });
  if (error) throw error;
  const j = (data ?? {}) as Record<string, unknown>;
  return { discount: Number(j.discount ?? 0), free_lines: Array.isArray(j.free_lines) ? (j.free_lines as { item_id: string; boxes: number; scheme: string }[]) : [] };
}
