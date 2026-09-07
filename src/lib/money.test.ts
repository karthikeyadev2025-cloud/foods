import { describe, expect, it } from 'vitest';
import { amountInWords, integerInWords } from './money';

describe('amount in words (Indian system)', () => {
  it('matches the quotation footer', () => {
    expect(amountInWords(34258)).toBe('Rupees Thirty Four thousand Two hundred Fifty Eight Only');
  });

  it('handles lakhs and crores', () => {
    expect(integerInWords(100000)).toBe('One lakh');
    expect(integerInWords(1234567)).toBe('Twelve lakh Thirty Four thousand Five hundred Sixty Seven');
    expect(integerInWords(10000000)).toBe('One crore');
    expect(integerInWords(123456789)).toBe('Twelve crore Thirty Four lakh Fifty Six thousand Seven hundred Eighty Nine');
  });

  it('spells paise and zero', () => {
    expect(amountInWords(0)).toBe('Rupees Zero Only');
    expect(amountInWords(12.5)).toBe('Rupees Twelve and Fifty Paise Only');
    expect(amountInWords(2688)).toBe('Rupees Two thousand Six hundred Eighty Eight Only');
  });
});
