import { describe, expect, it } from 'vitest';
import {
  boxRate,
  boxesToPieces,
  boxesToUnits,
  invoiceLine,
  invoiceTotals,
  normalizeItemCode,
  parsePackingFromName,
  piecesPerBox,
  unitsToBoxes,
} from './units';

/** The client's real quotation (docs/reference/quotation.jpeg) — the T2.2 acceptance test. */
const QUOTATION = [
  { code: '8', jars: 32, boxes: 2, rate: 42 },
  { code: '2', jars: 48, boxes: 3, rate: 40 },
  { code: '200A', jars: 1, boxes: 3, rate: 100 },
  { code: '1', jars: 8, boxes: 3, rate: 120 },
  { code: '57', jars: 24, boxes: 4, rate: 40 },
  { code: '44', jars: 32, boxes: 2, rate: 40 },
  { code: '2686', jars: 24, boxes: 1, rate: 40 },
  { code: '83', jars: 21, boxes: 1, rate: 40 },
  { code: '87', jars: 8, boxes: 1, rate: 120 },
  { code: '31', jars: 8, boxes: 1, rate: 120 },
  { code: '80', jars: 15, boxes: 2, rate: 42 },
  { code: '50', jars: 15, boxes: 1, rate: 58 },
  { code: '68', jars: 60, boxes: 2, rate: 36 },
  { code: '2702', jars: 32, boxes: 1, rate: 40 },
  { code: '2504', jars: 32, boxes: 2, rate: 40 },
  { code: '137', jars: 6, boxes: 2, rate: 105 },
  { code: '1262', jars: 24, boxes: 1, rate: 40 },
];

describe('invoice line maths', () => {
  it('row 1: Jars 32 × Boxes 2 = Qty 64 × Rate 42 = 2,688', () => {
    const l = invoiceLine({ boxes: 2, rate: 42, unitsPerBox: 32 });
    expect(l.jars).toBe(32);
    expect(l.qty).toBe(64);
    expect(l.total).toBe(2688);
  });

  it('reproduces the quotation: 17 lines, 32 boxes, 753 qty, net ₹34,258.00', () => {
    const lines = QUOTATION.map((q) => invoiceLine({ boxes: q.boxes, rate: q.rate, unitsPerBox: q.jars }));
    expect(lines).toHaveLength(17);
    const t = invoiceTotals(lines);
    expect(t.totalBoxes).toBe(32);
    expect(t.totalQty).toBe(753);
    expect(t.netAmount).toBe(34258);
  });

  it('refuses a zero or missing packing instead of falling back to 8', () => {
    expect(() => invoiceLine({ boxes: 1, rate: 10, unitsPerBox: 0 })).toThrow();
    expect(() => invoiceLine({ boxes: 1, rate: 10, unitsPerBox: Number.NaN })).toThrow();
  });
});

describe('packing conversions', () => {
  const laddu = { unitsPerBox: 48, piecesPerUnit: 12 }; // 5/- BOONDI LADDU (12) 48

  it('1 box = 48 packs = 576 pieces', () => {
    expect(boxesToUnits(1, laddu)).toBe(48);
    expect(boxesToPieces(1, laddu)).toBe(576);
    expect(piecesPerBox(laddu)).toBe(576);
    expect(unitsToBoxes(96, laddu)).toBe(2);
  });

  it('box rate is unit_rate × units_per_box', () => {
    expect(boxRate(42, { unitsPerBox: 32, piecesPerUnit: 12 })).toBe(1344);
  });

  it('allows negative quantities to flow through (stock is flagged, never clamped)', () => {
    expect(unitsToBoxes(-16, { unitsPerBox: 8, piecesPerUnit: 8 })).toBe(-2);
  });
});

describe('parsePackingFromName', () => {
  it('reads MRP, pieces and units from the name', () => {
    expect(parsePackingFromName('5/- BOONDI LADDU (12) 48')).toEqual({ mrpPerPiece: 5, piecesPerUnit: 12, unitsPerBox: 48 });
    expect(parsePackingFromName('5/- BOONDI LADDU (8)')).toEqual({ mrpPerPiece: 5, piecesPerUnit: 8 });
    expect(parsePackingFromName('5/- BOONDI CHIKKI (12)24 NEW')).toEqual({ mrpPerPiece: 5, piecesPerUnit: 12, unitsPerBox: 24 });
    expect(parsePackingFromName('5/- KAJA PKTS (12) 24P')).toEqual({ mrpPerPiece: 5, piecesPerUnit: 12, unitsPerBox: 24 });
    expect(parsePackingFromName('LOOSE BURFI')).toEqual({});
  });
});

describe('normalizeItemCode', () => {
  it('strips spaces and colons, upper-cases, never zero-pads', () => {
    expect(normalizeItemCode('27 A')).toBe('27A');
    expect(normalizeItemCode('06: A')).toBe('06A');
    expect(normalizeItemCode('83b')).toBe('83B');
    expect(normalizeItemCode('200A')).toBe('200A');
  });
});
