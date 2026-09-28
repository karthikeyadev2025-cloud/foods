import { searchCustomers, type CustomerRow } from '@/features/customers/api';
import { searchSuppliers, type SupplierRow } from './api';

/**
 * Who a purchase can be raised against.
 *
 * "They done both supply and purchase" — the shop buys from and sells to the
 * same people. Somebody who has always been typed into Customers turns up with
 * a lorry, and the supplier box could not find them: not a missing name, a
 * missing ROLE.
 *
 * So the box searches both lists. Suppliers are used as they are. A customer is
 * offered as somebody to ADD as a supplier — one click, pre-filled from what is
 * already known about them — because a purchase posts to the payable ledger and
 * a payable needs a supplier row to hang off.
 *
 * The two ledgers stay apart on purpose. What a party owes the shop and what
 * the shop owes them are different figures, and quietly netting them would turn
 * two facts into one number nobody can check.
 */
export interface PartyOption {
  /** Unique across both lists — customers and suppliers can share an id space. */
  key: string;
  kind: 'supplier' | 'customer';
  /** Set when kind is 'supplier': ready to put on the bill. */
  supplier: SupplierRow | null;
  /** Set when kind is 'customer': has to become a supplier first. */
  customer: CustomerRow | null;
  name: string;
  town: string | null;
  mobile1: string | null;
  /** What the shop owes them. Zero for a customer who is not a supplier yet. */
  payable: number;
}

/** Upper case, letters and digits only — "P. SRINIVAS (MCL)" and "P SRINIVAS MCL" are one party. */
export function samePartyName(a: string | null | undefined, b: string | null | undefined): boolean {
  const norm = (s: string | null | undefined) => (s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  const x = norm(a);
  return x !== '' && x === norm(b);
}

/** Ten digits, so +91 and spacing never make one person look like two. */
export function samePartyPhone(a: string | null | undefined, b: string | null | undefined): boolean {
  const digits = (s: string | null | undefined) => (s ?? '').replace(/\D/g, '').slice(-10);
  const x = digits(a);
  return x.length === 10 && x === digits(b);
}

/**
 * Fold the two searches into one list.
 *
 * A customer who is ALREADY a supplier is dropped from the customer half —
 * otherwise the same person appears twice and whichever row is clicked decides
 * whether the shop ends up with one payable or two. Matched on the name or the
 * mobile, because the two records were typed months apart by different hands.
 */
export function mergeParties(suppliers: SupplierRow[], customers: CustomerRow[]): PartyOption[] {
  const asSupplier: PartyOption[] = suppliers.map((s) => ({
    key: `s:${s.id}`,
    kind: 'supplier',
    supplier: s,
    customer: null,
    name: s.name ?? '',
    town: s.town ?? null,
    mobile1: s.mobile1 ?? null,
    payable: Number(s.payable ?? 0),
  }));

  const alreadySupplier = (c: CustomerRow) =>
    suppliers.some((s) => samePartyName(s.name, c.name) || samePartyPhone(s.mobile1, c.mobile1));

  const asCustomer: PartyOption[] = customers
    .filter((c) => !alreadySupplier(c))
    .map((c) => ({
      key: `c:${c.id}`,
      kind: 'customer',
      supplier: null,
      customer: c,
      name: c.name ?? '',
      town: c.town ?? null,
      mobile1: c.mobile1 ?? null,
      payable: 0,
    }));

  // Suppliers first: on a purchase screen, somebody who already supplies is
  // almost always the one meant.
  return [...asSupplier, ...asCustomer];
}

/** The supplier box's search: both lists, merged, suppliers first. */
export async function searchParties(q: string): Promise<PartyOption[]> {
  const [suppliers, customers] = await Promise.all([
    searchSuppliers(q),
    // A customer who cannot be found is simply not offered; the supplier half
    // of the box must keep working even if this call fails.
    searchCustomers(q).catch(() => [] as CustomerRow[]),
  ]);
  return mergeParties(suppliers, customers);
}
