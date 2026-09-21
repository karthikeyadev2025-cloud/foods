/**
 * Every money / qty / date display in the app goes through here (DOMAIN_RULES.md rule 7).
 *
 *   money(34258)      → "₹34,258.00"
 *   amount(34258)     → "34,258.00"      (no ₹ — for table cells and print grids)
 *   qty(64)           → "64.00"
 *   qty(0.667, 3)     → "0.667"
 *   int(753)          → "753"
 *   dateDMY("2026-08-25") → "25-08-2025"… (DD-MM-YYYY)
 *
 * Indian grouping (12,34,567.00) is what the client's registers use.
 */

const INR_2 = new Intl.NumberFormat('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const INR_0 = new Intl.NumberFormat('en-IN', { minimumFractionDigits: 0, maximumFractionDigits: 0 });

export type Numeric = number | string | null | undefined;

/** Postgres `numeric` arrives as a string over PostgREST; normalise once, at the edge. */
export function toNumber(v: Numeric): number {
  if (v === null || v === undefined || v === '') return 0;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** Round half away from zero to `dp` places, avoiding the classic 1.005 → 1.00 float slip. */
export function round(v: Numeric, dp = 2): number {
  const n = toNumber(v);
  if (n === 0) return 0;
  const sign = n < 0 ? -1 : 1;
  // Shift the decimal point in string form so 1.005 becomes exactly 100.5, not 100.49999…
  const shifted = Number(`${Math.abs(n)}e${dp}`);
  const rounded = Number(`${Math.round(shifted)}e-${dp}`);
  return sign * rounded;
}

/** "34,258.00" — two decimals, Indian grouping, no currency sign. */
export function amount(v: Numeric): string {
  return INR_2.format(round(v, 2));
}

/** "₹34,258.00" — money with the rupee prefix. Negative → "-₹1,200.00". */
export function money(v: Numeric): string {
  const n = round(v, 2);
  const s = INR_2.format(Math.abs(n));
  return n < 0 ? `-₹${s}` : `₹${s}`;
}

/**
 * Quantity, with the zeros that mean nothing left off: 32, 14.5, 13.88.
 *
 * `dp` is the MOST decimals shown, not a fixed width. "32.00 boxes" is noise a
 * shopkeeper has to read past on every line of every screen and every printed
 * sheet; "32" is the answer. What it must never do is round a real part-box away — 13.88 boxes of
 * a 48-jar box is 666 jars, and calling that 14 would misstate the shelf by
 * half a dozen. So the fraction survives whenever there is one.
 */
export function qty(v: Numeric, dp = 2): string {
  const n = round(v, dp);
  return new Intl.NumberFormat('en-IN', { minimumFractionDigits: 0, maximumFractionDigits: dp }).format(n);
}


/**
 * A count of things that cannot be part of themselves: boxes off the line,
 * jars filled, pieces made, plates put up.
 *
 * Rounded, not cut — 46.9 boxes is 47 boxes, not 46. This is the opposite end
 * from qty(): a shelf really can hold 13.88 boxes and saying 14 would misstate
 * it, but nobody ever filled 369.47 jars, and printing that on the production
 * sheet only makes the chief read past it.
 */
export function whole(v: Numeric): string {
  return INR_0.format(round(v, 0));
}

/**
 * A stock figure as the shop says it out loud: "2 + 3" — two boxes and three
 * loose jars — rather than "2.25".
 *
 * The quarter box is real. Twenty-seven jars of a twelve-jar pack IS two and a
 * quarter boxes, and rounding it to 2 would hide three jars off the shelf. But
 * nobody in a godown counts quarters of a box, so the fraction is shown as what
 * it actually is: the loose units left over.
 *
 * Falls back to a plain number when there is nothing to split into — a product
 * sold one to a box, or a weight.
 */
export function boxesAndUnits(boxes: Numeric, unitsPerBox: Numeric): string {
  const upb = Math.round(toNumber(unitsPerBox));
  const b = toNumber(boxes);
  if (upb <= 1) return qty(b);

  // Counted in whole units and split back, so 2.9999 from a division never
  // prints as "2 + 12" — twelve twelfths is one box.
  const units = Math.round(Math.abs(b) * upb);
  const full = Math.trunc(units / upb);
  const loose = units - full * upb;
  const body = loose === 0 ? int(full) : `${int(full)} + ${loose}`;
  // Bracketed when negative: "-2 + 3" reads as arithmetic and would be taken
  // for 1. Negative stock is a real state and it has to be unmistakable.
  return b < 0 ? (loose === 0 ? `-${body}` : `-(${body})`) : body;
}

/** Whole-number count with grouping: 1,234. */
export function int(v: Numeric): string {
  return INR_0.format(Math.trunc(toNumber(v)));
}

/** Parse a Postgres `date` (YYYY-MM-DD) or ISO timestamp into a local Date. */
export function parseDate(v: string | Date | null | undefined): Date | null {
  if (!v) return null;
  if (v instanceof Date) return Number.isNaN(v.getTime()) ? null : v;
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v);
  if (m) return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

const pad2 = (n: number) => String(n).padStart(2, '0');

/** DD-MM-YYYY, the client's convention on every printed document. */
export function dateDMY(v: string | Date | null | undefined): string {
  const d = parseDate(v);
  if (!d) return '';
  return `${pad2(d.getDate())}-${pad2(d.getMonth() + 1)}-${d.getFullYear()}`;
}

/** DD-MM-YYYY HH:MM (24h). */
export function dateTimeDMY(v: string | Date | null | undefined): string {
  const d = parseDate(v);
  if (!d) return '';
  return `${dateDMY(d)} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** YYYY-MM-DD in local time — what Postgres `date` columns and <input type="date"> want. */
export function toISODate(d: Date = new Date()): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** "5/- BOONDI LADDU (12) 48" style names are shown verbatim — never re-cased. This is a no-op guard. */
export function itemName(name: string): string {
  return name;
}
