/**
 * EAN-13 rendering for labels. The DB makes the numbers (db/16_inventory.sql
 * `generate_barcodes`, `ean13_check`); this only draws them.
 */

const L = ['0001101', '0011001', '0010011', '0111101', '0100011', '0110001', '0101111', '0111011', '0110111', '0001011'];
const G = ['0100111', '0110011', '0011011', '0100001', '0011101', '0111001', '0000101', '0010001', '0001001', '0010111'];
const R = ['1110010', '1100110', '1101100', '1000010', '1011100', '1001110', '1010000', '1000100', '1001000', '1110100'];
/** Which of the six left digits use the G set, keyed by the first digit. */
const PARITY = ['LLLLLL', 'LLGLGG', 'LLGGLG', 'LLGGGL', 'LGLLGG', 'LGGLLG', 'LGGGLL', 'LGLGLG', 'LGLGGL', 'LGGLGL'];

export function ean13CheckDigit(body12: string): string {
  if (!/^\d{12}$/.test(body12)) throw new Error('EAN-13 needs 12 digits');
  let sum = 0;
  for (let i = 0; i < 12; i++) sum += Number(body12[i]) * (i % 2 === 0 ? 1 : 3);
  return String((10 - (sum % 10)) % 10);
}

export function isValidEan13(code: string): boolean {
  return /^\d{13}$/.test(code) && ean13CheckDigit(code.slice(0, 12)) === code[12];
}

/** The 95-module bar pattern (1 = bar) for a valid 13-digit code. */
export function ean13Modules(code: string): string {
  if (!isValidEan13(code)) throw new Error(`Not a valid EAN-13: ${code}`);
  const first = Number(code[0]);
  const parity = PARITY[first] ?? PARITY[0]!;
  let out = '101';
  for (let i = 1; i <= 6; i++) out += (parity[i - 1] === 'G' ? G : L)[Number(code[i])];
  out += '01010';
  for (let i = 7; i <= 12; i++) out += R[Number(code[i])];
  return out + '101';
}

/** Inline SVG for a label. `height` is the bar height in modules of `moduleWidth` px. */
export function ean13Svg(code: string, opts: { moduleWidth?: number; height?: number; text?: boolean } = {}): string {
  const mw = opts.moduleWidth ?? 2;
  const h = opts.height ?? 50;
  const mods = ean13Modules(code);
  const width = 95 * mw + 22 * mw;
  const rects: string[] = [];
  let x = 11 * mw;
  for (let i = 0; i < mods.length; i++) {
    const guard = i < 3 || (i >= 45 && i < 50) || i >= 92;
    if (mods[i] === '1') rects.push(`<rect x="${x}" y="0" width="${mw}" height="${guard ? h + 5 : h}" fill="#000"/>`);
    x += mw;
  }
  const text = opts.text === false ? '' : `<text x="${4 * mw}" y="${h + 12}" font-size="${5 * mw}" font-family="monospace">${code[0]}</text><text x="${(11 + 3 + 21) * mw}" y="${h + 12}" font-size="${5 * mw}" font-family="monospace" text-anchor="middle">${code.slice(1, 7)}</text><text x="${(11 + 50 + 21) * mw}" y="${h + 12}" font-size="${5 * mw}" font-family="monospace" text-anchor="middle">${code.slice(7)}</text>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${h + 16}" viewBox="0 0 ${width} ${h + 16}">${rects.join('')}${text}</svg>`;
}

/** True when the typed text looks like a scanner burst rather than a CODE or a name. */
export function looksLikeBarcode(text: string): boolean {
  return /^\s*\d{8,14}\s*$/.test(text);
}
