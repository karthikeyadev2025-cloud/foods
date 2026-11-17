import { describe, expect, it } from 'vitest';
import { billMessage, docMessage, firstPhone, waLink, waNumber, type BillLine } from './whatsapp';

const LINES: BillLine[] = [
  { code: '8', name: 'MYSOOR PAK', boxes: 5, rate: 100, amount: 500 },
  { code: '12', name: 'KAJU PAKAM', boxes: 2, rate: 1240, amount: 2480 },
];

describe('the number', () => {
  it('puts the country code on a plain ten-digit mobile', () => {
    expect(waNumber('9849686746')).toBe('919849686746');
  });

  it('accepts a number however the shop typed it', () => {
    expect(waNumber('98496 86746')).toBe('919849686746');
    expect(waNumber('98496-86746')).toBe('919849686746');
    expect(waNumber('+91 98496 86746')).toBe('919849686746');
    expect(waNumber('0091-9849686746')).toBe('919849686746');
    expect(waNumber('09849686746')).toBe('919849686746');
  });

  it('leaves a number that already has its country code alone', () => {
    expect(waNumber('919849686746')).toBe('919849686746');
    expect(waNumber('971501234567')).toBe('971501234567'); // a customer in Dubai
  });

  it('refuses what is not a number, so the button can say why', () => {
    expect(waNumber('')).toBeNull();
    expect(waNumber(null)).toBeNull();
    expect(waNumber(undefined)).toBeNull();
    expect(waNumber('n/a')).toBeNull();
    expect(waNumber('98496')).toBeNull();
    expect(waNumber('1234567890123456789')).toBeNull();
  });
});

describe('the message', () => {
  const base = {
    orgName: 'JYOTHI FOODS',
    customerName: 'RAVI STORES',
    invoiceNo: '0041',
    invoiceDate: '14-11-2026',
    lines: LINES,
    total: 2980,
  };

  it('is the bill, not a note about one', () => {
    const m = billMessage(base);
    expect(m).toContain('JYOTHI FOODS');
    expect(m).toContain('Bill 0041 dated 14-11-2026');
    expect(m).toContain('8 MYSOOR PAK - 5 box x 100.00 = 500.00');
    expect(m).toContain('12 KAJU PAKAM - 2 box x 1,240.00 = 2,480.00');
    expect(m).toContain('Total Rs 2,980.00');
    expect(m).toContain('Thank you, RAVI STORES.');
  });

  it('writes rupees the Indian way, which is the only way a shop reads them', () => {
    expect(billMessage({ ...base, total: 1250000 })).toContain('Total Rs 12,50,000.00');
  });

  it('mentions money received and owing only when there is some', () => {
    const paid = billMessage({ ...base, received: 1000, balance: 1980 });
    expect(paid).toContain('Received Rs 1,000.00');
    expect(paid).toContain('Balance Rs 1,980.00');

    const settled = billMessage({ ...base, received: 2980, balance: 0 });
    expect(settled).toContain('Received Rs 2,980.00');
    expect(settled).not.toContain('Balance');

    const unpaid = billMessage(base);
    expect(unpaid).not.toContain('Received');
    expect(unpaid).not.toContain('Balance');
  });

  it('calls a draft an estimate, because a draft is not a bill', () => {
    expect(billMessage({ ...base, isProforma: true })).toContain('Estimate 0041');
    expect(billMessage({ ...base, isProforma: true })).not.toContain('Bill 0041');
  });

  it('summarises a very long bill instead of sending forty pages', () => {
    const many: BillLine[] = Array.from({ length: 55 }, (_, i) => ({
      code: String(i + 1), name: `ITEM ${i + 1}`, boxes: 1, rate: 10, amount: 10,
    }));
    const m = billMessage({ ...base, lines: many });
    expect(m).toContain('... and 15 more items');
    expect(m).toContain('ITEM 40');
    expect(m).not.toContain('ITEM 41 ');
  });

  it('carries the bill note when there is one', () => {
    expect(billMessage({ ...base, note: 'Goods once sold are not returnable' })).toContain('Goods once sold are not returnable');
  });
});

describe('the link', () => {
  it('opens WhatsApp with the message already typed', () => {
    const link = waLink('919849686746', 'Bill 0041\nTotal Rs 2,980.00');
    expect(link.startsWith('https://wa.me/919849686746?text=')).toBe(true);
    // the newline and the comma have to survive the trip
    expect(decodeURIComponent(link.split('?text=')[1] ?? '')).toBe('Bill 0041\nTotal Rs 2,980.00');
  });

  it('escapes what would otherwise cut the message short', () => {
    // A bare # or & in a bill note would end the query string.
    const link = waLink('919849686746', 'Lot #4 & #5');
    expect(link).not.toContain('#');
    expect(decodeURIComponent(link.split('?text=')[1] ?? '')).toBe('Lot #4 & #5');
  });
});

describe('the short message that goes with a PDF', () => {
  it('says which document and what it comes to, and stops', () => {
    const m = docMessage({
      orgName: 'JYOTHI FOODS', orgPhone: '79894 28599', label: 'Invoice', number: '0041',
      date: '17-11-2026', partyName: 'RAVI STORES', total: 2980, balance: 1980,
    });
    expect(m).toBe(
      'JYOTHI FOODS\nInvoice 0041 dated 17-11-2026\n\nTotal Rs 2,980.00\nBalance Rs 1,980.00\n\nThank you, RAVI STORES.\nJYOTHI FOODS - 79894 28599',
    );
    // the items are in the attached PDF, not repeated here
    expect(m).not.toContain('box x');
  });

  it('leaves the money out of a challan, which has none', () => {
    const m = docMessage({ orgName: 'JYOTHI FOODS', label: 'Delivery challan', number: 'DC-9', date: '17-11-2026' });
    expect(m).toContain('Delivery challan DC-9 dated 17-11-2026');
    expect(m).not.toContain('Total');
    expect(m).toContain('Thank you.');
  });

  it('says nothing about a balance that is settled', () => {
    const m = docMessage({ orgName: 'X', label: 'Invoice', number: '1', date: '17-11-2026', total: 500, balance: 0 });
    expect(m).toContain('Total Rs 500.00');
    expect(m).not.toContain('Balance');
  });
});

describe('the party phone', () => {
  it('takes the first of the numbers the sheet already lists', () => {
    expect(firstPhone('9849686746,9000000002,9000000003')).toBe('9849686746');
    expect(firstPhone('9849686746')).toBe('9849686746');
  });

  it('is null when there is none', () => {
    expect(firstPhone('')).toBeNull();
    expect(firstPhone(null)).toBeNull();
    expect(firstPhone(undefined)).toBeNull();
  });
});
