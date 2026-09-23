import { z } from 'zod';
import type { CustomerInsert } from './api';

/**
 * The short form behind "+ New customer" on the bill, receipt and return
 * screens.
 *
 * Name, mobile, town and route — what a bill needs and what makes the customer
 * findable again tomorrow. Credit limit, price group, language, WhatsApp and
 * the opening balance are left to the Customers screen: they are decisions, not
 * details, and none of them should be taken with somebody waiting at the
 * counter.
 *
 * The opening balance especially. A customer created mid-bill owes nothing yet;
 * typing a figure there in a hurry would put money in the ledger that never
 * existed.
 */
export const quickCustomerSchema = z.object({
  name: z.string().trim().min(1, 'Name is required').max(120),
  // Required here exactly as it is on the full form — it is the duplicate
  // check, and a customer with no number cannot be sent a bill or chased.
  mobile1: z
    .string()
    .trim()
    .max(20)
    .refine((s) => s.replace(/\D/g, '').length >= 10, 'Enter a 10-digit mobile number'),
  town: z.string().trim().max(80),
  route_id: z.string(),
});

export type QuickCustomer = z.infer<typeof quickCustomerSchema>;

export function quickCustomerValues(v: QuickCustomer): CustomerInsert {
  return {
    name: v.name.trim(),
    mobile1: v.mobile1.trim(),
    town: v.town.trim() || null,
    route_id: v.route_id || null,
    is_active: true,
  };
}
