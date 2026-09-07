import { describe, expect, it } from 'vitest';
import { amount, dateDMY, int, money, qty, round, toISODate, toNumber } from './format';

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
    expect(qty(32)).toBe('32.00');
    expect(int(753)).toBe('753');
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
