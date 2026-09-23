import { describe, expect, it } from 'vitest';
import { quickCustomerSchema, quickCustomerValues, type QuickCustomer } from './quick';
import { quickSupplierSchema, quickSupplierValues, type QuickSupplier } from '../purchases/quick';

const customer: QuickCustomer = { name: 'P. SRINIVAS (MCL)', mobile1: '9849686746', town: 'MACHARLA', route_id: 'r1' };
const supplier: QuickSupplier = { name: 'SUGAR TRADERS', mobile1: '9849686746', town: 'GUNTUR' };

describe('quickCustomerValues', () => {
  it('keeps the name exactly as the shop writes it, trimmed', () => {
    expect(quickCustomerValues({ ...customer, name: '  P. SRINIVAS (MCL) ' }).name).toBe('P. SRINIVAS (MCL)');
  });

  it('sends an unset town or route as null, never as an empty string', () => {
    const v = quickCustomerValues({ ...customer, town: '', route_id: '' });
    expect(v.town).toBeNull();
    expect(v.route_id).toBeNull();
  });

  // Nothing here may invent money. A customer created mid-bill owes nothing
  // yet, and an opening balance typed in a hurry is a debt in the ledger that
  // never existed.
  it('never sets an opening balance or a credit limit', () => {
    const v = quickCustomerValues(customer) as Record<string, unknown>;
    expect(v.opening_balance).toBeUndefined();
    expect(v.credit_limit).toBeUndefined();
  });

  it('creates the customer active', () => {
    expect(quickCustomerValues(customer).is_active).toBe(true);
  });
});

describe('quickCustomerSchema', () => {
  it('requires a name', () => {
    expect(quickCustomerSchema.safeParse({ ...customer, name: '  ' }).success).toBe(false);
  });

  // The mobile is the duplicate check on the full form, so it cannot be
  // optional on the short one: two rows for one shop means two ledgers, and the
  // money goes to whichever the next person happens to pick.
  it('requires a real ten-digit mobile', () => {
    expect(quickCustomerSchema.safeParse({ ...customer, mobile1: '' }).success).toBe(false);
    expect(quickCustomerSchema.safeParse({ ...customer, mobile1: '98496' }).success).toBe(false);
    expect(quickCustomerSchema.safeParse({ ...customer, mobile1: '98496 86746' }).success).toBe(true);
    expect(quickCustomerSchema.safeParse({ ...customer, mobile1: '+91 98496 86746' }).success).toBe(true);
  });

  it('lets the town and route be left for later', () => {
    expect(quickCustomerSchema.safeParse({ ...customer, town: '', route_id: '' }).success).toBe(true);
  });
});

describe('quickSupplierValues', () => {
  it('sends an unset mobile or town as null', () => {
    const v = quickSupplierValues({ ...supplier, mobile1: '', town: '' });
    expect(v.mobile1).toBeNull();
    expect(v.town).toBeNull();
  });

  // Same rule as the customer, and for the same reason: what the shop already
  // owes a supplier is a figure off a real statement, not a guess made while a
  // lorry is being unloaded.
  it('never sets an opening balance', () => {
    expect((quickSupplierValues(supplier) as Record<string, unknown>).opening_balance).toBeUndefined();
  });
});

describe('quickSupplierSchema', () => {
  it('requires a name', () => {
    expect(quickSupplierSchema.safeParse({ ...supplier, name: '' }).success).toBe(false);
  });

  // Unlike a customer: a cash supplier turning up with a lorry may have no
  // number on the bill, and refusing to record them at all is worse than a blank.
  it('allows no mobile at all, but not half a one', () => {
    expect(quickSupplierSchema.safeParse({ ...supplier, mobile1: '' }).success).toBe(true);
    expect(quickSupplierSchema.safeParse({ ...supplier, mobile1: '98496' }).success).toBe(false);
  });
});
