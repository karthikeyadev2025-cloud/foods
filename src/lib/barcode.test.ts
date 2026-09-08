import { describe, expect, it } from 'vitest';
import { ean13CheckDigit, ean13Modules, ean13Svg, isValidEan13, looksLikeBarcode } from './barcode';

describe('EAN-13', () => {
  it('computes the same check digit as the database', () => {
    expect(ean13CheckDigit('200000000011')).toBe('4');
    expect(ean13CheckDigit('400638133393')).toBe('1'); // a well-known retail code
  });
  it('validates', () => {
    expect(isValidEan13('2000000000114')).toBe(true);
    expect(isValidEan13('2000000000115')).toBe(false);
    expect(isValidEan13('123')).toBe(false);
  });
  it('encodes 95 modules with guards', () => {
    const m = ean13Modules('4006381333931');
    expect(m).toHaveLength(95);
    expect(m.startsWith('101')).toBe(true);
    expect(m.slice(45, 50)).toBe('01010');
    expect(m.endsWith('101')).toBe(true);
  });
  it('draws an svg', () => {
    const svg = ean13Svg('2000000000114');
    expect(svg.startsWith('<svg')).toBe(true);
    expect(svg).toContain('<rect');
    expect(svg).toContain('000000');
  });
  it('spots scanner input', () => {
    expect(looksLikeBarcode('2000000000114')).toBe(true);
    expect(looksLikeBarcode('27 A')).toBe(false);
    expect(looksLikeBarcode('8')).toBe(false);
  });
});
