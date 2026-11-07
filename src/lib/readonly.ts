/**
 * The whole app, frozen.
 *
 * When a licence has lapsed the database already refuses every new document
 * (db/18 enforce_license). That is the boundary and it holds. But the screen
 * would still let somebody fill in a bill, press Save, and only then find out
 * — in front of a customer — and the masters do not go through the document
 * tables at all, so a new item or customer would have saved quite happily
 * while the till was dead.
 *
 * So writes stop here too, at the one place every one of them passes through,
 * rather than at sixty-seven call sites that each have to remember. A button
 * that slips past the permission checks now does nothing except say why.
 *
 * Reading, printing and exporting are untouched: the shop can still look up
 * what a customer owes and print yesterday's bill. It simply cannot add
 * anything until the account is settled.
 */

/** The message a shopkeeper sees. Not "403", not "licence invalid". */
export const READ_ONLY_MESSAGE =
  'The app is read-only until the account is settled — nothing new can be saved. Everything can still be opened, printed and exported.';

export class ReadOnlyError extends Error {
  constructor(message = READ_ONLY_MESSAGE) {
    super(message);
    this.name = 'ReadOnlyError';
  }
}

let readOnly = false;

/**
 * Set from license_status(), which the app asks on start-up and every half
 * hour — so a lock, or a payment, takes hold within the half hour without
 * anybody signing out.
 */
export function setReadOnly(value: boolean): void {
  readOnly = value;
}

export function isReadOnly(): boolean {
  return readOnly;
}

/** Throws when the licence has lapsed. Called before every write. */
export function assertWritable(): void {
  if (readOnly) throw new ReadOnlyError();
}
