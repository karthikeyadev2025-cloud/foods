import { z } from 'zod';
import type { SupplierInsert } from './api';

/**
 * The short form behind "+ New supplier" on the purchase and purchase-return
 * screens.
 *
 * Shorter than the customer's, because a supplier is: a name, someone to ring,
 * and where they are. The opening balance — what the shop already owes them —
 * is left to the Suppliers screen. It is a real figure off a real statement,
 * and guessing it while a delivery is being entered would put a debt in the
 * ledger that nobody can account for.
 */
export const quickSupplierSchema = z.object({
  name: z.string().trim().min(1, 'Name is required').max(120),
  // Not required: a cash supplier who turns up with a lorry may have no number
  // on the bill, and refusing to record them at all is worse than a blank.
  mobile1: z
    .string()
    .trim()
    .max(20)
    .refine((s) => s === '' || s.replace(/\D/g, '').length >= 10, 'Enter a 10-digit mobile number'),
  town: z.string().trim().max(80),
});

export type QuickSupplier = z.infer<typeof quickSupplierSchema>;

export function quickSupplierValues(v: QuickSupplier): SupplierInsert {
  return {
    name: v.name.trim(),
    mobile1: v.mobile1.trim() || null,
    town: v.town.trim() || null,
    is_active: true,
  };
}
