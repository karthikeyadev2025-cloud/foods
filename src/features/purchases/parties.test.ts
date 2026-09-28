import { describe, expect, it } from 'vitest';
import type { CustomerRow } from '@/features/customers/api';
import type { SupplierRow } from './api';
import { mergeParties, samePartyName, samePartyPhone } from './parties';

const supplier = (name: string, extra: Partial<SupplierRow> = {}) =>
  ({ id: `s-${name}`, name, town: null, mobile1: null, payable: 0, is_active: true, ...extra }) as SupplierRow;
const customer = (name: string, extra: Partial<CustomerRow> = {}) =>
  ({ id: `c-${name}`, name, town: null, mobile1: null, outstanding: 0, is_active: true, ...extra }) as CustomerRow;

/**
 * "They done both supply and purchase" — the shop buys from and sells to the
 * same people. The purchase screen now searches both lists, and the whole risk
 * of that is showing one person twice: click the wrong row and the shop keeps
 * two payable balances for one party, neither of which is what it owes.
 */
describe('mergeParties', () => {
  it('offers suppliers first — on a purchase screen that is usually who is meant', () => {
    const out = mergeParties([supplier('BALAJI AGENCIES')], [customer('AAA TRADERS')]);
    expect(out.map((p) => p.kind)).toEqual(['supplier', 'customer']);
  });

  it('marks a customer as needing to be added, and a supplier as ready', () => {
    const out = mergeParties([supplier('BALAJI AGENCIES')], [customer('P. SRINIVAS (MCL)')]);
    expect(out[0]?.supplier).not.toBeNull();
    expect(out[1]?.customer).not.toBeNull();
    expect(out[1]?.supplier).toBeNull();
  });

  // The one that matters. The same person typed into both lists, months apart,
  // by different hands.
  it('shows a party once when they are already a supplier, however the name was typed', () => {
    const out = mergeParties(
      [supplier('P. SRINIVAS (MCL)')],
      [customer('P SRINIVAS MCL'), customer('RAVI STORES')],
    );
    expect(out.map((p) => p.name)).toEqual(['P. SRINIVAS (MCL)', 'RAVI STORES']);
  });

  it('spots the same party by mobile even when the names read differently', () => {
    const out = mergeParties(
      [supplier('SRINIVAS GENERAL STORES', { mobile1: '9849686746' })],
      [customer('P. SRINIVAS', { mobile1: '+91 98496 86746' })],
    );
    expect(out).toHaveLength(1);
    expect(out[0]?.kind).toBe('supplier');
  });

  it('keeps two genuinely different parties apart', () => {
    const out = mergeParties(
      [supplier('SRI LAKSHMI TRADERS', { mobile1: '9000000001' })],
      [customer('SRI LAKSHMI STORES', { mobile1: '9000000002' })],
    );
    expect(out).toHaveLength(2);
  });

  it('carries the payable through for a supplier, and shows nothing owed to a customer yet', () => {
    const out = mergeParties([supplier('BALAJI', { payable: 4500 })], [customer('RAVI')]);
    expect(out[0]?.payable).toBe(4500);
    expect(out[1]?.payable).toBe(0);
  });

  it('gives every row a key that cannot collide across the two lists', () => {
    const out = mergeParties([supplier('A')], [customer('B')]);
    expect(new Set(out.map((p) => p.key)).size).toBe(out.length);
  });
});

describe('samePartyName', () => {
  it('ignores punctuation, spacing and case', () => {
    expect(samePartyName('P. SRINIVAS (MCL)', 'p srinivas mcl')).toBe(true);
    expect(samePartyName('R.K.BAKERY', 'RK BAKERY')).toBe(true);
  });

  it('does not match two parties that merely look alike', () => {
    expect(samePartyName('SRI LAKSHMI TRADERS', 'SRI LAKSHMI STORES')).toBe(false);
  });

  // An empty name matching an empty name would fold every unnamed row into one.
  it('never matches on nothing', () => {
    expect(samePartyName('', '')).toBe(false);
    expect(samePartyName(null, undefined)).toBe(false);
    expect(samePartyName('...', '---')).toBe(false);
  });
});

describe('samePartyPhone', () => {
  it('compares the last ten digits, so +91 and spacing do not split one person', () => {
    expect(samePartyPhone('+91 98496 86746', '9849686746')).toBe(true);
    expect(samePartyPhone('098496-86746', '9849686746')).toBe(true);
  });

  it('will not match a half-typed number', () => {
    expect(samePartyPhone('98496', '98496')).toBe(false);
    expect(samePartyPhone('', '')).toBe(false);
    expect(samePartyPhone(null, null)).toBe(false);
  });

  it('keeps different numbers apart', () => {
    expect(samePartyPhone('9849686746', '9849686747')).toBe(false);
  });
});
