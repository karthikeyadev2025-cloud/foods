/**
 * Boxes ↔ units ↔ pieces conversion.
 *
 * The item master is the only source of packing figures (DOMAIN_RULES.md, "masters define,
 * transactions derive"). Nothing here defaults `units_per_box` to 8 — a missing or zero
 * packing is an error, not a fallback.
 *
 *   5/- BOONDI LADDU (12) 48   →  { unitsPerBox: 48, piecesPerUnit: 12 }
 *   1 box = 48 packs = 576 pieces
 */
import { round } from './format';

export interface Packing {
  /** Jars / packs / L.B units in one box — the "Jars" column on the quotation. */
  unitsPerBox: number;
  /** Pieces in one unit — the "(12)" inside the item name. */
  piecesPerUnit: number;
}

function assertPacking(p: Packing): void {
  if (!Number.isFinite(p.unitsPerBox) || p.unitsPerBox <= 0) {
    throw new Error(`units_per_box must be a positive number, got ${p.unitsPerBox}`);
  }
  if (!Number.isFinite(p.piecesPerUnit) || p.piecesPerUnit <= 0) {
    throw new Error(`pieces_per_unit must be a positive number, got ${p.piecesPerUnit}`);
  }
}

export function boxesToUnits(boxes: number, p: Packing): number {
  assertPacking(p);
  return boxes * p.unitsPerBox;
}

export function unitsToBoxes(units: number, p: Packing): number {
  assertPacking(p);
  return units / p.unitsPerBox;
}

export function unitsToPieces(units: number, p: Packing): number {
  assertPacking(p);
  return units * p.piecesPerUnit;
}

export function piecesToUnits(pieces: number, p: Packing): number {
  assertPacking(p);
  return pieces / p.piecesPerUnit;
}

export function boxesToPieces(boxes: number, p: Packing): number {
  return unitsToPieces(boxesToUnits(boxes, p), p);
}

export function piecesToBoxes(pieces: number, p: Packing): number {
  return unitsToBoxes(piecesToUnits(pieces, p), p);
}

/** Pieces in one box — shown on Add Product's derived panel. */
export function piecesPerBox(p: Packing): number {
  assertPacking(p);
  return p.unitsPerBox * p.piecesPerUnit;
}

/** Box rate is always computed, never typed: unit_rate × units_per_box. */
export function boxRate(unitRate: number, p: Packing): number {
  assertPacking(p);
  return round(unitRate * p.unitsPerBox, 2);
}

export interface InvoiceLineInput {
  /** What the operator types. */
  boxes: number;
  /** Rate per UNIT (jar / pack / L.B), never per box. Defaults from the master. */
  rate: number;
  /** Snapshot of the item's packing at billing time. */
  unitsPerBox: number;
}

export interface InvoiceLine extends InvoiceLineInput {
  /** "Jars" column — the snapshot units_per_box, shown read-only. */
  jars: number;
  /** Qty = boxes × units_per_box. */
  qty: number;
  /** Total = qty × rate, rounded to paise. */
  total: number;
}

/**
 * The quotation's line maths. The operator types CODE, Boxes and Rate; everything
 * else is derived and read-only on screen.
 *
 *   Jars 32 × Boxes 2 = Qty 64 × Rate 42.00 = ₹2,688.00
 */
export function invoiceLine(input: InvoiceLineInput): InvoiceLine {
  if (!Number.isFinite(input.unitsPerBox) || input.unitsPerBox <= 0) {
    throw new Error(`units_per_box must be a positive number, got ${input.unitsPerBox}`);
  }
  const qty = round(input.boxes * input.unitsPerBox, 3);
  const total = round(qty * input.rate, 2);
  return { ...input, jars: input.unitsPerBox, qty, total };
}

export interface InvoiceTotals {
  totalBoxes: number;
  totalQty: number;
  netAmount: number;
}

/** Footer figures: total boxes, total qty, net amount. */
export function invoiceTotals(lines: readonly Pick<InvoiceLine, 'boxes' | 'qty' | 'total'>[]): InvoiceTotals {
  let totalBoxes = 0;
  let totalQty = 0;
  let netAmount = 0;
  for (const l of lines) {
    totalBoxes += l.boxes;
    totalQty += l.qty;
    netAmount += l.total;
  }
  return { totalBoxes: round(totalBoxes, 3), totalQty: round(totalQty, 3), netAmount: round(netAmount, 2) };
}

/**
 * Parse the packing hints encoded in an item name. This only ever pre-fills Add
 * Product — the stored master columns are the truth, not the name.
 *
 *   "5/- BOONDI LADDU (12) 48"  → { mrpPerPiece: 5, piecesPerUnit: 12, unitsPerBox: 48 }
 *   "5/- BOONDI LADDU (8)"      → { mrpPerPiece: 5, piecesPerUnit: 8,  unitsPerBox: undefined }
 *   "LOOSE BURFI"               → {}
 */
export function parsePackingFromName(name: string): Partial<Packing> & { mrpPerPiece?: number } {
  const out: Partial<Packing> & { mrpPerPiece?: number } = {};
  const mrp = /^\s*(\d+)\s*\/-/.exec(name);
  if (mrp) out.mrpPerPiece = Number(mrp[1]);
  const pieces = /\((\d+)\s*[A-Za-z]?\)/.exec(name);
  if (pieces) out.piecesPerUnit = Number(pieces[1]);
  const trailing = /\)\s*(\d+)\s*[A-Za-z]?\s*(?:NEW)?\s*$/i.exec(name);
  if (trailing) out.unitsPerBox = Number(trailing[1]);
  return out;
}

/**
 * Item codes are TEXT. Normalise the way the client's spreadsheets need:
 * strip spaces and colons, upper-case. Never cast to int, never zero-pad.
 *
 *   "27 A" → "27A"   "06: A" → "06A"   "83b" → "83B"
 */
export function normalizeItemCode(code: string): string {
  return code.replace(/[\s:]+/g, '').toUpperCase();
}
