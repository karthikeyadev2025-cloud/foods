import { describe, expect, it } from 'vitest';
import { quickItemSchema, quickItemValues, type QuickItem } from './quick';

const base: QuickItem = {
  item_code: '2760',
  name: '1/- KALAJAM(12)',
  type: 'finished_good',
  pack_type_id: 'pack-jar',
  base_uom_id: 'uom-jar',
  units_per_box: 12,
  rate: 10,
};

/**
 * A product created in a hurry is still a master record. A wrong units_per_box
 * here quietly misstates the godown on every bill it ever appears on — which is
 * the same fault that made 51 boxes of a twelve-pack read as 4.25 (db/50).
 */
describe('quickItemValues', () => {
  it('writes the rate to the column the screen that asked for it uses', () => {
    expect(quickItemValues(base, 'purchase_rate')).toMatchObject({ purchase_rate: 10 });
    expect(quickItemValues(base, 'purchase_rate').unit_rate).toBeUndefined();
    expect(quickItemValues(base, 'unit_rate')).toMatchObject({ unit_rate: 10 });
    expect(quickItemValues(base, 'unit_rate').purchase_rate).toBeUndefined();
  });

  it('reads the pieces out of the name rather than asking for them again', () => {
    expect(quickItemValues(base, 'unit_rate').pieces_per_unit).toBe(12);
    expect(quickItemValues({ ...base, name: 'SWEET GULABI' }, 'unit_rate').pieces_per_unit).toBe(1);
  });

  it('keeps the units per box that was typed, never a guess', () => {
    expect(quickItemValues({ ...base, units_per_box: 6 }, 'unit_rate').units_per_box).toBe(6);
  });

  // Sugar is bought by the kilo. A "box" of it, and a pack-type label on it,
  // are both fictions — and a units_per_box of 12 on a sack would multiply
  // every purchase of it by twelve.
  it('gives a raw material no box packing and no pack type', () => {
    const v = quickItemValues({ ...base, name: 'SUGAR', type: 'raw_material', pack_type_id: '', units_per_box: 12 }, 'purchase_rate');
    expect(v.units_per_box).toBe(1);
    expect(v.pieces_per_unit).toBe(1);
    expect(v.pack_type_id).toBeNull();
  });

  it('normalises the code the way the shop writes a repack', () => {
    expect(quickItemValues({ ...base, item_code: '27 a' }, 'unit_rate').item_code).toBe('27A');
    expect(quickItemValues({ ...base, item_code: '06: A' }, 'unit_rate').item_code).toBe('06A');
  });

  it('sends an empty pack type as null, never as an empty string', () => {
    expect(quickItemValues({ ...base, type: 'packing_material', pack_type_id: '' }, 'purchase_rate').pack_type_id).toBeNull();
  });

  it('trims the name, which arrives from whatever was typed in the picker', () => {
    expect(quickItemValues({ ...base, name: '  SWEET GULABI  ' }, 'unit_rate').name).toBe('SWEET GULABI');
  });
});

describe('quickItemSchema', () => {
  it('will not create a product with no unit — the ledger would have nothing to count in', () => {
    const r = quickItemSchema.safeParse({ ...base, base_uom_id: '' });
    expect(r.success).toBe(false);
  });

  it('refuses a finished good with no pack type, as Add Product does', () => {
    const r = quickItemSchema.safeParse({ ...base, pack_type_id: '' });
    expect(r.success).toBe(false);
    expect(r.error?.issues[0]?.path).toEqual(['pack_type_id']);
  });

  it('lets a raw material through without one', () => {
    expect(quickItemSchema.safeParse({ ...base, type: 'raw_material', pack_type_id: '' }).success).toBe(true);
  });

  // Zero is the value a blank number field produces, and it is the one number
  // that must never be saved: every quantity on every bill is multiplied by it.
  it('refuses units per box of zero, and anything fractional', () => {
    expect(quickItemSchema.safeParse({ ...base, units_per_box: 0 }).success).toBe(false);
    expect(quickItemSchema.safeParse({ ...base, units_per_box: 2.5 }).success).toBe(false);
  });

  it('refuses a negative rate', () => {
    expect(quickItemSchema.safeParse({ ...base, rate: -1 }).success).toBe(false);
  });
});
