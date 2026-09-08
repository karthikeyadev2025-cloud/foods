import { currentOrgId } from '@/features/auth/api';
import { expectOk, expectOne, expectRows, supabase } from '@/lib/supabase';
import { rangeFor, sanitizeSearch, type Page, type PageQuery } from '@/lib/paging';
import type { Database, Json } from '@/types/supabase';

type Tables = Database['public']['Tables'];
type Views = Database['public']['Views'];
type Fns = Database['public']['Functions'];

export type Template = Tables['message_templates']['Row'];
export type ReminderRule = Tables['reminder_rules']['Row'];
export type ReminderRuleRow = Views['v_reminder_rules']['Row'];
export type NewStockRuleRow = Views['v_new_stock_rules']['Row'];
export type Catalog = Tables['catalogs']['Row'];
export type BroadcastRow = Views['v_broadcasts']['Row'];
export type MessageRow = Views['v_message_log']['Row'];
export type InboundOrderRow = Views['v_inbound_orders']['Row'];
export type DocMessageSetting = Tables['transaction_message_settings']['Row'];
export type InboundLine = Fns['inbound_order_lines']['Returns'][number];
export type ReminderRecipient = Fns['reminder_recipients']['Returns'][number];
export type BroadcastRecipient = Fns['broadcast_recipients']['Returns'][number];
export type MsgPurpose = Database['public']['Enums']['msg_purpose'];
export type MsgStatus = Database['public']['Enums']['msg_status'];
export type OrderStatus = Database['public']['Enums']['order_status'];

export const orderTone: Record<OrderStatus, 'default' | 'secondary' | 'destructive' | 'outline'> = { new: 'default', confirmed: 'secondary', invoiced: 'secondary', rejected: 'destructive' };

export const statusTone: Record<MsgStatus, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  queued: 'outline',
  sent: 'secondary',
  delivered: 'default',
  read: 'default',
  failed: 'destructive',
};

/** Which documents can auto-send, and the template purpose each expects. */
export const DOC_MESSAGE_TYPES: { doc_type: string; label: string; purpose: MsgPurpose; when: string }[] = [
  { doc_type: 'invoice', label: 'Invoice copy', purpose: 'invoice', when: 'when an invoice is dispatched' },
  { doc_type: 'delivery', label: 'Delivery confirmation', purpose: 'delivery', when: 'when an invoice is marked delivered' },
  { doc_type: 'receipt', label: 'Receipt thanks', purpose: 'custom', when: 'when a receipt is saved' },
  { doc_type: 'order_ack', label: 'Order acknowledgement', purpose: 'order_ack', when: 'when a WhatsApp / call order is converted' },
];

// ---------------- templates ----------------
export const templatesApi = {
  list: () => expectRows(supabase.from('message_templates').select('*').order('purpose').order('language').order('name')),
  create: async (v: Omit<Tables['message_templates']['Insert'], 'org_id'>) =>
    expectOne(supabase.from('message_templates').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id: string, v: Tables['message_templates']['Update']) =>
    expectOne(supabase.from('message_templates').update({ ...v, updated_at: new Date().toISOString() }).eq('id', id).select('*').single()),
  remove: (id: string) => expectOk(supabase.from('message_templates').delete().eq('id', id)),
};

// ---------------- reminder rules ----------------
export const reminderRulesApi = {
  list: (): Promise<ReminderRuleRow[]> => expectRows(supabase.from('v_reminder_rules').select('*').order('overdue_days')),
  create: async (v: Omit<Tables['reminder_rules']['Insert'], 'org_id'>) =>
    expectOne(supabase.from('reminder_rules').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id: string, v: Tables['reminder_rules']['Update']) =>
    expectOne(supabase.from('reminder_rules').update({ ...v, updated_at: new Date().toISOString() }).eq('id', id).select('*').single()),
  remove: (id: string) => expectOk(supabase.from('reminder_rules').delete().eq('id', id)),
};

export async function reminderRecipients(ruleId: string): Promise<ReminderRecipient[]> {
  const { data, error } = await supabase.rpc('reminder_recipients', { p_rule: ruleId });
  if (error) throw error;
  return data ?? [];
}

export interface RunResult {
  rule: string;
  dry_run: boolean;
  candidates: number;
  queued: number;
  skipped: { name: string; reason: string }[];
}

export async function runReminderRule(ruleId: string, dryRun: boolean): Promise<RunResult> {
  const { data, error } = await supabase.rpc('run_reminder_rule', { p_rule: ruleId, p_dry_run: dryRun });
  if (error) throw error;
  const j = (data ?? {}) as Record<string, unknown>;
  return {
    rule: String(j.rule ?? ''),
    dry_run: Boolean(j.dry_run),
    candidates: Number(j.candidates ?? 0),
    queued: Number(j.queued ?? 0),
    skipped: Array.isArray(j.skipped) ? (j.skipped as { name: string; reason: string }[]) : [],
  };
}

// ---------------- new stock rules ----------------
export const newStockRulesApi = {
  list: (): Promise<NewStockRuleRow[]> => expectRows(supabase.from('v_new_stock_rules').select('*').order('item_code')),
  create: async (v: Omit<Tables['new_stock_rules']['Insert'], 'org_id'>) =>
    expectOne(supabase.from('new_stock_rules').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id: string, v: Tables['new_stock_rules']['Update']) =>
    expectOne(supabase.from('new_stock_rules').update({ ...v, updated_at: new Date().toISOString() }).eq('id', id).select('*').single()),
  remove: (id: string) => expectOk(supabase.from('new_stock_rules').delete().eq('id', id)),
};

// ---------------- catalogs ----------------
export const catalogsApi = {
  list: (): Promise<Catalog[]> => expectRows(supabase.from('catalogs').select('*').order('created_at', { ascending: false })),
  create: async (v: Omit<Tables['catalogs']['Insert'], 'org_id'>) =>
    expectOne(supabase.from('catalogs').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id: string, v: Tables['catalogs']['Update']) =>
    expectOne(supabase.from('catalogs').update({ ...v, updated_at: new Date().toISOString() }).eq('id', id).select('*').single()),
  remove: (id: string) => expectOk(supabase.from('catalogs').delete().eq('id', id)),
};

/** PDF to the public `catalogs` bucket; returns the path and the URL Nikki will fetch. */
export async function uploadCatalogPdf(file: File): Promise<{ path: string; url: string }> {
  const org = await currentOrgId();
  const safe = file.name.replace(/[^a-zA-Z0-9._-]+/g, '_');
  const path = `${org}/${Date.now()}-${safe}`;
  const { error } = await supabase.storage.from('catalogs').upload(path, file, { contentType: 'application/pdf', upsert: false });
  if (error) throw error;
  const { data } = supabase.storage.from('catalogs').getPublicUrl(path);
  return { path, url: data.publicUrl };
}

// ---------------- broadcasts ----------------
export function listBroadcasts(): Promise<BroadcastRow[]> {
  return expectRows(supabase.from('v_broadcasts').select('*').order('created_at', { ascending: false }).limit(200));
}

export type BroadcastSegment = { route_id?: string; town?: string; bought_within_days?: number; bought_item_id?: string };
export type CreateBroadcastInput = {
  kind: 'new_stock' | 'catalog' | 'custom';
  item_id?: string;
  catalog_id?: string;
  template_id?: string;
  body?: string;
  segment: BroadcastSegment;
  note?: string;
};

export async function createBroadcast(input: CreateBroadcastInput): Promise<string> {
  const { data, error } = await supabase.rpc('create_broadcast', { p: { ...input, segment: { ...input.segment } } });
  if (error) throw error;
  return data;
}

export async function broadcastRecipients(id: string): Promise<BroadcastRecipient[]> {
  const { data, error } = await supabase.rpc('broadcast_recipients', { p_broadcast: id });
  if (error) throw error;
  return data ?? [];
}

export async function queueBroadcast(id: string): Promise<number> {
  const { data, error } = await supabase.rpc('queue_broadcast', { p_broadcast: id });
  if (error) throw error;
  return Number((data as Record<string, unknown> | null)?.queued ?? 0);
}

export function cancelBroadcast(id: string): Promise<void> {
  return expectOk(supabase.from('broadcasts').update({ status: 'cancelled' }).eq('id', id).eq('status', 'pending'));
}

// ---------------- message log ----------------
export interface MessageListQuery extends PageQuery {
  status?: MsgStatus | '';
  purpose?: MsgPurpose | '';
  from?: string;
  to?: string;
  customerId?: string;
}

function applyLogFilters(q: MessageListQuery) {
  let query = supabase.from('v_message_log').select('*', { count: 'exact' });
  const s = sanitizeSearch(q.search);
  if (s) query = query.or(`customer_name.ilike.%${s}%,to_number.ilike.%${s}%,body.ilike.%${s}%`);
  if (q.status) query = query.eq('status', q.status);
  if (q.purpose) query = query.eq('purpose', q.purpose);
  if (q.customerId) query = query.eq('customer_id', q.customerId);
  if (q.from) query = query.gte('created_at', `${q.from}T00:00:00`);
  if (q.to) query = query.lte('created_at', `${q.to}T23:59:59`);
  return query.order('created_at', { ascending: false });
}

export async function listMessages(q: MessageListQuery): Promise<Page<MessageRow>> {
  const [from, to] = rangeFor(q.page, q.pageSize);
  const { data, error, count } = await applyLogFilters(q).range(from, to);
  if (error) throw error;
  return { rows: data ?? [], total: count ?? 0, page: q.page, pageSize: q.pageSize };
}

export function listAllMessages(q: Omit<MessageListQuery, 'page' | 'pageSize'>): Promise<MessageRow[]> {
  return expectRows(applyLogFilters({ ...q, page: 1, pageSize: 5000 }).range(0, 4999));
}

export async function sendCustomMessage(customerId: string, body: string, mediaUrl?: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('send_custom_message', { p_customer: customerId, p_body: body, p_media_url: mediaUrl || undefined });
  if (error) throw error;
  return data;
}

// ---------------- settings ----------------
export interface MessagingSettings {
  api_url: string;
  has_api_key: boolean;
  api_key_hint: string | null;
  webhook_secret: string;
  sender_number: string | null;
  default_language: string;
  quiet_from: string;
  quiet_to: string;
  daily_cap: number;
  is_enabled: boolean;
  updated_at: string | null;
}

function toSettings(j: Json | null): MessagingSettings {
  const o = (j && typeof j === 'object' && !Array.isArray(j) ? j : {}) as Record<string, unknown>;
  return {
    api_url: String(o.api_url ?? 'https://heynikki.in'),
    has_api_key: Boolean(o.has_api_key),
    api_key_hint: o.api_key_hint ? String(o.api_key_hint) : null,
    webhook_secret: String(o.webhook_secret ?? ''),
    sender_number: o.sender_number ? String(o.sender_number) : null,
    default_language: String(o.default_language ?? 'te'),
    quiet_from: String(o.quiet_from ?? '21:00:00').slice(0, 5),
    quiet_to: String(o.quiet_to ?? '08:00:00').slice(0, 5),
    daily_cap: Number(o.daily_cap ?? 500),
    is_enabled: Boolean(o.is_enabled),
    updated_at: o.updated_at ? String(o.updated_at) : null,
  };
}

export async function getMessagingSettings(): Promise<MessagingSettings> {
  const { data, error } = await supabase.rpc('get_messaging_settings');
  if (error) throw error;
  return toSettings(data);
}

export type SettingsPatch = {
  api_url?: string;
  api_key?: string;
  sender_number?: string;
  default_language?: string;
  quiet_from?: string;
  quiet_to?: string;
  daily_cap?: number;
  is_enabled?: boolean;
};

export async function saveMessagingSettings(p: SettingsPatch): Promise<MessagingSettings> {
  const { data, error } = await supabase.rpc('save_messaging_settings', { p: { ...p } });
  if (error) throw error;
  return toSettings(data);
}

export async function rotateWebhookSecret(): Promise<string> {
  const { data, error } = await supabase.rpc('rotate_webhook_secret');
  if (error) throw error;
  return data;
}

export function listDocSettings(): Promise<DocMessageSetting[]> {
  return expectRows(supabase.from('transaction_message_settings').select('*'));
}

export async function saveDocSetting(docType: string, v: { is_enabled: boolean; template_id: string | null; send_pdf?: boolean }): Promise<void> {
  const org_id = await currentOrgId();
  await expectOk(supabase.from('transaction_message_settings').upsert({ org_id, doc_type: docType, ...v }, { onConflict: 'org_id,doc_type' }));
}

// ---------------- inbound orders ----------------
export function listInboundOrders(status: OrderStatus | ''): Promise<InboundOrderRow[]> {
  let query = supabase.from('v_inbound_orders').select('*');
  if (status) query = query.eq('status', status);
  return expectRows(query.order('created_at', { ascending: false }).limit(300));
}

export function getInboundOrder(id: string): Promise<InboundOrderRow> {
  return expectOne(supabase.from('v_inbound_orders').select('*').eq('id', id).single());
}

export async function inboundOrderLines(id: string): Promise<InboundLine[]> {
  const { data, error } = await supabase.rpc('inbound_order_lines', { p_order: id });
  if (error) throw error;
  return data ?? [];
}

export type ConvertHeader = { customer_id: string; invoice_date: string; location_id: string; notes?: string | null; freight: number; discount: number; round_off: number };
export type ConvertLine = { item_id: string; boxes: number; rate: number | null };

/** The human step: a draft invoice from the edited lines. Never called without someone pressing the button. */
export async function convertInboundOrder(id: string, header: ConvertHeader, lines: ConvertLine[]): Promise<string> {
  const { data, error } = await supabase.rpc('convert_inbound_order', { p_order: id, p_header: { ...header }, p_lines: lines.map((l) => ({ ...l })) });
  if (error) throw error;
  return data;
}

export async function rejectInboundOrder(id: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc('reject_inbound_order', { p_order: id, p_reason: reason || undefined });
  if (error) throw error;
}

export async function createInboundOrder(input: { customer_id?: string; from?: string; text: string; source: 'call' | 'manual'; notes?: string }): Promise<string> {
  const { data, error } = await supabase.rpc('create_inbound_order', { p: { ...input } });
  if (error) throw error;
  return data;
}
