import { z } from 'zod';
import { normalizeItemCode, parsePackingFromName } from '@/lib/units';
import type { ItemInsert } from './api';

/**
 * The short form behind "+ New product" on the bill and purchase screens.
 *
 * Everything Add Product asks for that a bill cannot do without, and nothing
 * else — no photo, no MRP, no shelf life, no reorder level. Those are worth
 * typing when somebody is setting the master up; they are not worth holding up
 * a supplier standing at the counter. They can be filled in later under Items.
 */
export const quickItemSchema = z
  .object({
    item_code: z.string().trim().min(1, 'Item code is required').max(20),
    name: z.string().trim().min(1, 'Item name is required').max(120),
    type: z.enum(['finished_good', 'raw_material', 'packing_material']),
    pack_type_id: z.string(),
    base_uom_id: z.string().min(1, 'Choose the unit stock is counted in'),
    units_per_box: z.coerce.number().int('Whole number').positive('Units per box is required — it is never assumed'),
    rate: z.coerce.number().min(0),
  })
  .superRefine((v, ctx) => {
    if (v.type === 'finished_good' && !v.pack_type_id) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['pack_type_id'], message: 'Finished goods need a pack type' });
    }
  });

export type QuickItem = z.infer<typeof quickItemSchema>;

/** Which rate column the screen that opened the dialog writes to. */
export type RateField = 'purchase_rate' | 'unit_rate';

/**
 * What actually gets written for a quick-created product.
 *
 * Kept apart from the dialog so the rules can be read and tested on their own —
 * a product created in a hurry is still a master record, and a wrong
 * units_per_box here quietly misstates the godown on every bill it ever
 * appears on.
 */
export function quickItemValues(v: QuickItem, rateField: RateField): ItemInsert {
  const finished = v.type === 'finished_good';
  const parsed = parsePackingFromName(v.name);
  return {
    item_code: normalizeItemCode(v.item_code),
    name: v.name.trim(),
    type: v.type,
    // A pack type is a label for a finished good. On a sack of sugar it is noise.
    pack_type_id: finished ? v.pack_type_id || null : null,
    base_uom_id: v.base_uom_id,
    // Raw and packing materials have no box packing: one unit is one unit.
    units_per_box: finished ? v.units_per_box : 1,
    // "1/- KALAJAM(12)" is twelve pieces to a jar. Read from the name rather
    // than asked for again, because a number already on the screen that has to
    // be re-typed is a number that gets typed wrong.
    pieces_per_unit: finished ? (parsed.piecesPerUnit ?? 1) : 1,
    [rateField]: v.rate,
    is_active: true,
  };
}
