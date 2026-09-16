import { describe, expect, it } from 'vitest';
import { numberSeriesSchema, numberingProblem, stampDate } from './schema';

const series = (over: Partial<Record<string, unknown>> = {}) => ({
  doc_type: 'invoice',
  prefix: '',
  suffix: '',
  width: 4,
  next_number: 1,
  reset_period: 'never',
  ...over,
});

describe('stampDate', () => {
  const on = new Date(2026, 8, 16); // September is month 8

  it('fills in every token', () => {
    expect(stampDate('{YYYY}-{YY}-{MM}-{DD}', on)).toBe('2026-26-09-16');
  });

  it('does not let {YY} eat the tail of {YYYY}', () => {
    expect(stampDate('{YYYY}/', on)).toBe('2026/');
  });

  it('pads a single-digit month and day', () => {
    expect(stampDate('{MM}{DD}', new Date(2026, 0, 5))).toBe('0105');
  });

  it('leaves a plain prefix alone', () => {
    expect(stampDate('INV/', on)).toBe('INV/');
  });
});

describe('numberingProblem', () => {
  it('passes a series that never resets, whatever the prefix', () => {
    expect(numberingProblem(series() as never)).toBeNull();
    expect(numberingProblem(series({ prefix: 'INV/' }) as never)).toBeNull();
  });

  // The shop's actual setting on the day the till threw 23505.
  it('catches a daily reset with no date in the number', () => {
    const problem = numberingProblem(series({ reset_period: 'daily' }) as never);
    expect(problem).toContain('every day');
    expect(problem).toContain('{YYYY}{MM}{DD}');
  });

  it('accepts a daily reset once the date is in the prefix', () => {
    expect(numberingProblem(series({ reset_period: 'daily', prefix: '{YY}{MM}{DD}/' }) as never)).toBeNull();
  });

  it('still catches a daily reset that is missing the day', () => {
    expect(numberingProblem(series({ reset_period: 'daily', prefix: '{YY}{MM}/' }) as never)).toContain('every day');
  });

  // Only the month means January 2027 lands back on January 2026's numbers.
  it('wants the year alongside the month', () => {
    expect(numberingProblem(series({ reset_period: 'monthly', prefix: '{MM}/' }) as never)).toContain('every month');
    expect(numberingProblem(series({ reset_period: 'monthly', prefix: '{YY}{MM}/' }) as never)).toBeNull();
  });

  it('takes the date from the suffix too', () => {
    expect(numberingProblem(series({ reset_period: 'yearly', suffix: '/{YYYY}' }) as never)).toBeNull();
  });
});

describe('numberSeriesSchema', () => {
  it('refuses to save the setting that caused the duplicate bill number', () => {
    const r = numberSeriesSchema.safeParse(series({ reset_period: 'daily' }));
    expect(r.success).toBe(false);
    // On the prefix field, because that is where the fix is typed.
    expect(r.success === false && r.error.issues[0]?.path).toEqual(['prefix']);
  });

  it('saves the same series once the prefix carries the date', () => {
    expect(numberSeriesSchema.safeParse(series({ reset_period: 'daily', prefix: '{YY}{MM}{DD}/' })).success).toBe(true);
  });

  it('still saves an ordinary series that never resets', () => {
    expect(numberSeriesSchema.safeParse(series({ prefix: 'INV/', width: 4 })).success).toBe(true);
  });
});
