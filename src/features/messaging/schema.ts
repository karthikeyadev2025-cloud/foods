import { z } from 'zod';

const name = z.string().trim().min(1, 'Name is required').max(120);

export const PURPOSES = [
  { value: 'payment_reminder', label: 'Payment reminder' },
  { value: 'invoice', label: 'Invoice copy (on dispatch)' },
  { value: 'delivery', label: 'Delivery confirmation' },
  { value: 'order_ack', label: 'Order acknowledgement' },
  { value: 'new_stock', label: 'New stock' },
  { value: 'catalog', label: 'Catalog' },
  { value: 'custom', label: 'Custom / receipt thanks' },
] as const;
export const LANGUAGES = [
  { value: 'te', label: 'Telugu' },
  { value: 'en', label: 'English' },
] as const;
export const CHANNELS = [
  { value: 'whatsapp', label: 'WhatsApp' },
  { value: 'sms', label: 'SMS' },
  { value: 'ivr_call', label: 'Voice call (script read out)' },
] as const;

export const templateSchema = z.object({
  name,
  purpose: z.enum(['payment_reminder', 'invoice', 'delivery', 'order_ack', 'new_stock', 'catalog', 'custom']),
  language: z.enum(['te', 'en']),
  channel: z.enum(['whatsapp', 'sms', 'ivr_call']),
  provider_template_name: z.string().trim().max(120),
  body: z.string().trim().min(1, 'The message body is required').max(2000),
  is_active: z.boolean(),
});
export type TemplateInput = z.infer<typeof templateSchema>;

export const reminderRuleSchema = z.object({
  name,
  template_id: z.string(),
  min_outstanding: z.coerce.number().min(0),
  overdue_days: z.coerce.number().int().min(0),
  repeat_every_days: z.coerce.number().int().min(1, 'At least one day between reminders'),
  channel: z.enum(['whatsapp', 'sms', 'ivr_call']),
  route_id: z.string(),
  is_active: z.boolean(),
});
export type ReminderRuleInput = z.infer<typeof reminderRuleSchema>;

export const newStockRuleSchema = z.object({
  item_id: z.string().min(1, 'Pick the item'),
  threshold_boxes: z.coerce.number().positive('Threshold must be above zero'),
  lookback_days: z.coerce.number().int().min(1),
  template_id: z.string(),
  auto_send: z.boolean(),
  is_active: z.boolean(),
});
export type NewStockRuleInput = z.infer<typeof newStockRuleSchema>;

export const catalogSchema = z.object({
  name,
  valid_from: z.string(),
  valid_to: z.string(),
  is_active: z.boolean(),
});
export type CatalogInput = z.infer<typeof catalogSchema>;

export const settingsSchema = z.object({
  is_enabled: z.boolean(),
  api_url: z.string().trim().url('Enter the full https:// address'),
  api_key: z.string().trim().max(200),
  sender_number: z.string().trim().max(20),
  default_language: z.enum(['te', 'en']),
  quiet_from: z.string(),
  quiet_to: z.string(),
  daily_cap: z.coerce.number().int().min(1),
  voice_enabled: z.boolean(),
  caller_number: z.string().trim().max(20),
  voice_name: z.string().trim().max(60),
  call_attempts: z.coerce.number().int().min(1).max(5),
  call_retry_minutes: z.coerce.number().int().min(5).max(1440),
});
export type SettingsInput = z.infer<typeof settingsSchema>;

export const broadcastSchema = z.object({
  template_id: z.string(),
  body: z.string().trim().max(2000),
  route_id: z.string(),
  town: z.string().trim().max(80),
  bought_within_days: z.coerce.number().int().min(0),
});
export type BroadcastInput = z.infer<typeof broadcastSchema>;
