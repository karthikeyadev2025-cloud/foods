import { z } from 'zod';

/**
 * Form schemas. Input and output types are kept identical (no defaults, no
 * transforms) so react-hook-form and zod agree on one type per form; the panels
 * normalise (uppercase codes, '' → null) before calling api.ts.
 */

const code = z.string().trim().min(1, 'Code is required').max(20);
const name = z.string().trim().min(1, 'Name is required').max(120);
const optionalText = z.string().trim().max(200);
const sortOrder = z.coerce.number().int().min(0);

export const UOM_BASES = [
  { value: 'box', label: 'Box (units per box × pieces)' },
  { value: 'unit', label: 'Unit — jar / pack / L.B' },
  { value: 'piece', label: 'Piece' },
  { value: 'weight', label: 'Weight (grams per 1)' },
] as const;

export const uomSchema = z.object({
  code,
  name,
  basis: z.enum(['box', 'unit', 'piece', 'weight']),
  weight_g: z.coerce.number().min(0),
  sort_order: sortOrder,
  is_active: z.boolean(),
});
export type UomInput = z.infer<typeof uomSchema>;

export const packTypeSchema = z.object({
  code,
  name: optionalText,
  sort_order: sortOrder,
  is_active: z.boolean(),
});
export type PackTypeInput = z.infer<typeof packTypeSchema>;

export const receiptModeSchema = z.object({
  code,
  name,
  is_collection: z.boolean(),
  needs_reference: z.boolean(),
  is_cheque: z.boolean(),
  account_id: z.string(),
  sort_order: sortOrder,
  is_active: z.boolean(),
});
export type ReceiptModeInput = z.infer<typeof receiptModeSchema>;

export const expenseHeadSchema = z.object({
  name,
  is_active: z.boolean(),
});
export type ExpenseHeadInput = z.infer<typeof expenseHeadSchema>;

export const sectionSchema = z.object({
  code: optionalText,
  name,
  mestri_id: z.string(),
  sort_order: sortOrder,
  is_active: z.boolean(),
});
export type SectionInput = z.infer<typeof sectionSchema>;

export const LOCATION_KINDS = [
  { value: 'godown', label: 'Godown' },
  { value: 'production_floor', label: 'Production floor' },
  { value: 'vehicle', label: 'Vehicle (normally created from Vehicles)' },
] as const;

export const stockLocationSchema = z.object({
  name,
  kind: z.enum(['godown', 'vehicle', 'production_floor']),
  is_active: z.boolean(),
});
export type StockLocationInput = z.infer<typeof stockLocationSchema>;

export const routeSchema = z.object({
  name,
  towns: z.string().trim().max(500),
  is_active: z.boolean(),
});
export type RouteInput = z.infer<typeof routeSchema>;

export const DOC_TYPES = [
  { value: 'invoice', label: 'Sales invoice' },
  { value: 'receipt', label: 'Receipt' },
  { value: 'purchase', label: 'Purchase' },
  { value: 'return', label: 'Sales return' },
  { value: 'payment', label: 'Payment' },
  { value: 'batch', label: 'Production batch' },
  { value: 'quotation', label: 'Quotation' },
  { value: 'order', label: 'Order' },
  { value: 'challan', label: 'Delivery challan' },
  { value: 'purchase_return', label: 'Purchase return' },
  { value: 'journal', label: 'Journal entry' },
] as const;

export const RESET_PERIODS = [
  { value: 'never', label: 'Never' },
  { value: 'yearly', label: 'Every year' },
  { value: 'monthly', label: 'Every month' },
  { value: 'daily', label: 'Every day' },
] as const;

export const numberSeriesSchema = z.object({
  doc_type: z.string().trim().min(1, 'Document type is required'),
  prefix: z.string().trim().max(20),
  suffix: z.string().trim().max(20),
  width: z.coerce.number().int().min(1, 'At least 1 digit').max(10),
  next_number: z.coerce.number().int().min(1),
  reset_period: z.enum(['never', 'yearly', 'monthly', 'daily']),
});
export type NumberSeriesInput = z.infer<typeof numberSeriesSchema>;

export const orgSchema = z.object({
  name,
  address: z.string().trim().max(500),
  phone: optionalText,
  fssai_no: optionalText,
  breakage_recovery_pct: z.coerce.number().min(0).max(100),
  interest_pct_pa: z.coerce.number().min(0).max(100),
  credit_days: z.coerce.number().int().min(0).max(365),
  jurisdiction: optionalText,
});
export type OrgInput = z.infer<typeof orgSchema>;

export const STAFF_ROLES = [
  'owner',
  'admin',
  'accountant',
  'store_keeper',
  'production_head',
  'chief',
  'driver',
  'sales_exec',
] as const;

export const newUserSchema = z.object({
  full_name: name,
  email: z.string().trim().min(1, 'Email is required').email('Enter a valid email'),
  password: z.string().min(8, 'At least 8 characters'),
  phone: optionalText,
  role: z.enum(STAFF_ROLES),
  is_mestry: z.boolean(),
  daily_wage: z.coerce.number().min(0),
});
export type NewUserInput = z.infer<typeof newUserSchema>;

export const editUserSchema = z.object({
  full_name: name,
  phone: optionalText,
  role: z.enum(STAFF_ROLES),
  is_mestry: z.boolean(),
  daily_wage: z.coerce.number().min(0),
  is_active: z.boolean(),
});
export type EditUserInput = z.infer<typeof editUserSchema>;

/** '' → null for nullable text columns. */
export const orNull = (s: string): string | null => (s.trim() === '' ? null : s.trim());
