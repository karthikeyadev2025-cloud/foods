import { describe, expect, it } from 'vitest';
import { amount, boxesAndUnits, dateDMY, int, money, qty, round, toISODate, toNumber, whole } from './format';

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

  // The production sheet read "Expected boxes 46.18 · 369.47 jars". Nobody
  // ever filled forty-seven hundredths of a jar.
  it('shows a count of whole things without a decimal point', () => {
    expect(whole(46.18)).toBe('46');
    expect(whole(369.47)).toBe('369');
    expect(whole(-2.18)).toBe('-2');
    expect(whole(44)).toBe('44');
  });

  it('rounds a count rather than cutting it, unlike int()', () => {
    expect(whole(46.9)).toBe('47');
    expect(int(46.9)).toBe('46');
  });

  it('groups a large count the Indian way', () => {
    expect(whole(1234567)).toBe('12,34,567');
  });

  it('leaves a part box alone where a shelf can really hold one', () => {
    expect(qty(13.88)).toBe('13.88');
  });

  // The shop asked three times why the stock screen shows a point. It is real:
  // 27 jars of a twelve-jar pack IS 2.25 boxes. Rounding would hide three jars,
  // so the fraction is shown as what it is instead.
  describe('boxesAndUnits', () => {
    it('splits the shop\'s own figure into boxes and loose jars', () => {
      expect(boxesAndUnits(2.25, 12)).toBe('2 + 3');
    });

    it('says nothing extra when the boxes are whole', () => {
      expect(boxesAndUnits(39, 6)).toBe('39');
      expect(boxesAndUnits(0, 12)).toBe('0');
    });

    it('never prints a full box as loose units', () => {
      // 2.99999 x 12 rounds to 36 jars, which is three boxes and nothing over.
      expect(boxesAndUnits(2.9999999, 12)).toBe('3');
    });

    it('brackets a negative, because "-2 + 3" reads as arithmetic', () => {
      expect(boxesAndUnits(-2.25, 12)).toBe('-(2 + 3)');
      expect(boxesAndUnits(-3, 12)).toBe('-3');
    });

    it('leaves a product sold one to a box alone', () => {
      expect(boxesAndUnits(30, 1)).toBe('30');
      expect(boxesAndUnits(4.5, 0)).toBe('4.5');
    });

    it('groups a large figure the Indian way', () => {
      expect(boxesAndUnits(123456.5, 2)).toBe('1,23,456 + 1');
    });
  });

  it('formats dates as DD-MM-YYYY', () => {
    expect(dateDMY('2026-08-25')).toBe('25-08-2026');
    expect(dateDMY(null)).toBe('');
    expect(toISODate(new Date(2026, 7, 25))).toBe('2026-08-25');
  });
});
