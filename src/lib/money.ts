/**
 * Amount in words, Indian system, matching the client's printed quotation:
 *
 *   34258 → "Rupees Thirty Four thousand Two hundred Fifty Eight Only"
 *
 * Crore / lakh / thousand / hundred grouping. Paise are spelled out when present.
 */

const ONES = [
  '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
  'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen',
] as const;
const TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'] as const;

function below100(n: number): string {
  if (n < 20) return ONES[n] ?? '';
  const t = TENS[Math.floor(n / 10)] ?? '';
  const o = ONES[n % 10] ?? '';
  return o ? `${t} ${o}` : t;
}

function below1000(n: number): string {
  const h = Math.floor(n / 100);
  const rest = n % 100;
  const parts: string[] = [];
  if (h) parts.push(`${ONES[h]} hundred`);
  if (rest) parts.push(below100(rest));
  return parts.join(' ');
}

/** Integer rupees → words (no "Rupees"/"Only" wrapper). 0 → "Zero". */
export function integerInWords(n: number): string {
  const v = Math.trunc(Math.abs(n));
  if (v === 0) return 'Zero';
  const crore = Math.floor(v / 10_000_000);
  const lakh = Math.floor((v % 10_000_000) / 100_000);
  const thousand = Math.floor((v % 100_000) / 1000);
  const rest = v % 1000;

  const parts: string[] = [];
  if (crore) parts.push(`${integerInWords(crore)} crore`);
  if (lakh) parts.push(`${below100(lakh)} lakh`);
  if (thousand) parts.push(`${below100(thousand)} thousand`);
  if (rest) parts.push(below1000(rest));
  return parts.join(' ');
}

/** Full printed form: "Rupees Thirty Four thousand Two hundred Fifty Eight Only". */
export function amountInWords(v: number): string {
  const sign = v < 0 ? 'Minus ' : '';
  const abs = Math.abs(v);
  const rupees = Math.floor(abs + 1e-9);
  const paise = Math.round((abs - rupees) * 100);
  let s = `${sign}Rupees ${integerInWords(rupees)}`;
  if (paise > 0) s += ` and ${below100(paise)} Paise`;
  return `${s} Only`;
}
