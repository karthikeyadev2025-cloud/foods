import { describe, expect, it } from 'vitest';
import { amount, dateDMY, int, money, qty, qtyFixed, round, toISODate, toNumber } from './format';

describe('format', () => {
  it('groups the Indian way with two decimals', () => {
    expect(amount(34258)).toBe('34,258.00');
    expect(amount(2688)).toBe('2,688.00');
    expect(amount(1234567.5)).toBe('12,34,567.50');
    expect(amount('960')).toBe('960.00');
  });

  it('prefixes ₹ on money only', () => {
    expect(money(34258)).toBe('₹34,258.00');
    expect(money(-1200)).toBe('-₹1,200.00');
    expect(qty(32)).toBe('32');
    expect(int(753)).toBe('753');
  });

  it('leaves off the decimals that mean nothing, and keeps the ones that do', () => {
    expect(qty(32)).toBe('32');
    expect(qty(14.5)).toBe('14.5');
    expect(qty(14.50)).toBe('14.5');
    // A real part-box must survive: 13.88 of a 48-jar box is 666 jars, and
    // calling it 14 would misstate the shelf by half a dozen.
    expect(qty(13.875)).toBe('13.88');
    expect(qty(-13.88)).toBe('-13.88');
    expect(qty(0)).toBe('0');
    expect(qty(1234.5)).toBe('1,234.5');
    // dp is the most decimals, not a fixed width.
    expect(qty(2.5, 0)).toBe('3');
    expect(qty(1.5, 3)).toBe('1.5');
    expect(qty(1.2344, 3)).toBe('1.234');
    expect(qty(1.2345, 3)).toBe('1.235');   // half away from zero, as round() does
  });

  it('keeps the decimals on a printed document, where the column has to line up', () => {
    expect(qtyFixed(32)).toBe('32.00');
    expect(qtyFixed(14.5)).toBe('14.50');
    expect(qtyFixed(13.875)).toBe('13.88');
    expect(qtyFixed(5, 3)).toBe('5.000');
  });

  it('rounds half away from zero without float slips', () => {
    expect(round(1.005)).toBe(1.01);
    expect(round(2.675)).toBe(2.68);
    expect(round(-1.005)).toBe(-1.01);
    expect(round(0.6666, 3)).toBe(0.667);
  });

  it('treats PostgREST numeric strings and nulls at the edge', () => {
    expect(toNumber('42.00')).toBe(42);
    expect(toNumber(null)).toBe(0);
    expect(toNumber('abc')).toBe(0);
  });

  it('formats dates as DD-MM-YYYY', () => {
    expect(dateDMY('2026-08-25')).toBe('25-08-2026');
    expect(dateDMY(null)).toBe('');
    expect(toISODate(new Date(2026, 7, 25))).toBe('2026-08-25');
  });
});
