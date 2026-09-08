import { z } from 'zod';

const mobile = z
  .string()
  .trim()
  .max(20)
  .refine((s) => s === '' || s.replace(/\D/g, '').length >= 10, 'Enter a 10-digit mobile number');

export const customerSchema = z.object({
  name: z.string().trim().min(1, 'Name is required').max(120),
  code: z.string().trim().max(20),
  mobile1: mobile.refine((s) => s !== '', 'Mobile 1 is required — it is the duplicate check'),
  mobile2: mobile,
  mobile3: mobile,
  town: z.string().trim().max(80),
  address: z.string().trim().max(500),
  route_id: z.string(),
  price_group: z.string().trim().max(40),
  credit_limit: z.coerce.number().min(0),
  opening_balance: z.coerce.number(),
  whatsapp_opt_in: z.boolean(),
  language: z.enum(['te', 'en']),
  is_active: z.boolean(),
});

export type CustomerInput = z.infer<typeof customerSchema>;

export const CUSTOMER_DEFAULTS: CustomerInput = {
  name: '',
  code: '',
  mobile1: '',
  mobile2: '',
  mobile3: '',
  town: '',
  address: '',
  route_id: '',
  price_group: 'default',
  credit_limit: 0,
  opening_balance: 0,
  whatsapp_opt_in: true,
  language: 'te',
  is_active: true,
};

/** Digits only — the importer and the duplicate check normalise the same way. */
export const digits = (s: string): string => s.replace(/\D/g, '');
