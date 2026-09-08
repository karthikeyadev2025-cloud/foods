import { supabase } from '@/lib/supabase';

/**
 * Hey Nikki from the browser. The API key never comes here: the app only queues rows in
 * message_log (RPCs in db/13_messaging.sql) and asks the `nikki-send` edge function to
 * drain the queue. Delivery updates and inbound orders arrive on the webhooks.
 */

/** Placeholders a template may use; the DB fills the same names (render_template). */
export const TEMPLATE_VARS: { key: string; meaning: string; used: string }[] = [
  { key: 'name', meaning: 'Customer name', used: 'all' },
  { key: 'town', meaning: 'Customer town', used: 'all' },
  { key: 'org', meaning: 'Your business name', used: 'all' },
  { key: 'outstanding', meaning: 'Live outstanding, e.g. 2,688.00', used: 'all' },
  { key: 'date', meaning: 'Today, DD-MM-YYYY', used: 'all' },
  { key: 'oldest_days', meaning: 'Days the oldest bill is overdue', used: 'payment reminders' },
  { key: 'invoice_no', meaning: 'Invoice number', used: 'invoice copy, delivery, order acknowledgement' },
  { key: 'amount', meaning: 'Document amount', used: 'invoice, delivery, order, receipt' },
  { key: 'items', meaning: 'Lines as "code × boxes, …"', used: 'invoice, delivery, order' },
  { key: 'boxes', meaning: 'Total boxes on the bill', used: 'invoice, delivery, order' },
  { key: 'receipt_no', meaning: 'Receipt number', used: 'receipt thanks' },
  { key: 'item', meaning: 'Item name', used: 'new stock' },
  { key: 'item_code', meaning: 'Item code', used: 'new stock' },
  { key: 'catalog', meaning: 'Catalog name', used: 'catalog' },
  { key: 'valid_to', meaning: 'Catalog valid till', used: 'catalog' },
];

/** Same rule as the DB: replace known {{keys}}, leave unknown ones visible. */
export function renderTemplate(body: string, vars: Record<string, string | number | null | undefined>): string {
  let out = body;
  for (const [k, v] of Object.entries(vars)) out = out.split(`{{${k}}}`).join(v === null || v === undefined ? '' : String(v));
  return out;
}

/** Placeholders present in a body that are not in TEMPLATE_VARS — a typo the screen can flag. */
export function unknownPlaceholders(body: string): string[] {
  const known = new Set(TEMPLATE_VARS.map((v) => v.key));
  const found = new Set<string>();
  for (const m of body.matchAll(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g)) if (m[1] && !known.has(m[1])) found.add(m[1]);
  return [...found];
}

export interface DrainResult {
  org_id: string;
  claimed: number;
  sent: number;
  failed: number;
  skipped_reason?: string;
}

/** Ask the edge function to send whatever the queue allows now (switch, quiet hours, cap). */
export async function sendQueuedNow(): Promise<DrainResult> {
  const { data, error } = await supabase.functions.invoke<{ results: DrainResult[] } | { error: string }>('nikki-send', { body: {} });
  if (error) throw error;
  if (!data || 'error' in data) throw new Error(data?.error ?? 'nikki-send returned nothing');
  return data.results[0] ?? { org_id: '', claimed: 0, sent: 0, failed: 0, skipped_reason: 'no organisation' };
}

export interface ReminderRunResult {
  rule: string;
  dry_run: boolean;
  candidates: number;
  queued: number;
  skipped: { name: string; reason: string }[];
}

/** Run every active reminder rule now and send; what pg_cron does at 10:00. */
export async function runRemindersNow(): Promise<{ runs: ReminderRunResult[]; sends: DrainResult[] }> {
  const { data, error } = await supabase.functions.invoke<{ runs: ReminderRunResult[]; sends: DrainResult[] } | { error: string }>('run-reminders', { body: {} });
  if (error) throw error;
  if (!data || 'error' in data) throw new Error(data?.error ?? 'run-reminders returned nothing');
  return data;
}

/** Webhook URLs to paste into the Hey Nikki console. */
export function webhookUrls(): { inbound: string; status: string } {
  const base = (import.meta.env.VITE_SUPABASE_URL ?? '').replace(/\/$/, '');
  return { inbound: `${base}/functions/v1/nikki-inbound`, status: `${base}/functions/v1/nikki-status` };
}
