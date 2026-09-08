import { z } from 'zod';

export const ITEM_TYPES = [
  { value: 'finished_good', label: 'Finished good (sold in boxes)' },
  { value: 'raw_material', label: 'Raw material (used in production)' },
  { value: 'packing_material', label: 'Packing material' },
] as const;

/**
 * Add Product — the only place packing and pricing are ever entered.
 * Input and output types are identical so react-hook-form and zod agree.
 */
export const itemSchema = z
  .object({
    item_code: z.string().trim().min(1, 'Item code is required').max(20),
    name: z.string().trim().min(1, 'Item name is required').max(120),
    type: z.enum(['finished_good', 'raw_material', 'packing_material']),
    pack_type_id: z.string(),
    section_id: z.string(),
    base_uom_id: z.string().min(1, 'Choose the unit stock is kept in'),
    units_per_box: z.coerce.number().int('Whole number').positive('Units per box is required — it is never assumed'),
    pieces_per_unit: z.coerce.number().int('Whole number').positive('At least 1 piece per unit'),
    mrp_per_piece: z.coerce.number().min(0),
    net_weight_g: z.coerce.number().min(0),
    unit_rate: z.coerce.number().min(0),
    purchase_rate: z.coerce.number().min(0),
    reorder_level: z.coerce.number().min(0),
    shelf_life_days: z.coerce.number().int().min(0),
    is_active: z.boolean(),
    /** Public URL of the product photo, '' when none. Set by the upload, never typed. */
    image_url: z.string(),
  })
  .superRefine((v, ctx) => {
    if (v.type === 'finished_good' && !v.pack_type_id) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['pack_type_id'], message: 'Finished goods need a pack type' });
    }
  });

export type ItemInput = z.infer<typeof itemSchema>;

export const ITEM_DEFAULTS: ItemInput = {
  item_code: '',
  name: '',
  type: 'finished_good',
  pack_type_id: '',
  section_id: '',
  base_uom_id: '',
  units_per_box: 0,
  pieces_per_unit: 1,
  mrp_per_piece: 0,
  net_weight_g: 0,
  unit_rate: 0,
  purchase_rate: 0,
  reorder_level: 0,
  shelf_life_days: 0,
  is_active: true,
  image_url: '',
};
