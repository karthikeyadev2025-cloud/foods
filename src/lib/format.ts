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

/** Quantity with fixed decimals (default 2, matching the quotation's "32.00"). */
export function qty(v: Numeric, dp = 2): string {
  const n = round(v, dp);
  return new Intl.NumberFormat('en-IN', { minimumFractionDigits: dp, maximumFractionDigits: dp }).format(n);
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
