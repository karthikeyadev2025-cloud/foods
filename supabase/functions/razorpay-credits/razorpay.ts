// What the Razorpay webhook has to get right, kept apart from the request
// handling so it can be tested without a payment provider.
//
// All of it is the security boundary: these four functions are what stands
// between "anyone on the internet can POST here" and "credits, which are
// money, are handed out".

/** HMAC-SHA256 of the raw body, hex, as Razorpay signs it. */
export async function signBody(secret: string, raw: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw));
  return Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/**
 * Compare two digests without leaking where the first difference is.
 *
 * Both sides are walked to the end whatever happens. A loop that returns on
 * the first wrong character takes measurably less time, which tells a caller
 * how much of a guess was right — and a signature that can be checked a byte
 * at a time can be found a byte at a time.
 */
export function sameDigest(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

type Entity = Record<string, unknown>;
export type Notes = Record<string, unknown> | undefined;

const entity = (body: Entity, k: string): Entity | null => {
  const payload = (body.payload ?? {}) as Entity;
  const e = (payload[k] as Entity | undefined)?.entity;
  return e && typeof e === 'object' ? (e as Entity) : null;
};

/**
 * The payment out of whichever event shape arrived. A payment link, a QR code
 * and a plain card payment all carry the payment entity in the same place;
 * events that carry no payment (order.paid on its own, a refund) return null,
 * because there is nothing there to turn into credits.
 */
export function paymentOf(body: Entity): Entity | null {
  return entity(body, 'payment');
}

/**
 * Which shop paid, in the payment notes. Notes can sit on the payment, the
 * order, the payment link or the QR code depending on how the supplier set the
 * payment up, so all four are looked at, nearest first.
 */
export function notesOf(body: Entity): Notes {
  for (const k of ['payment', 'order', 'payment_link', 'qr_code']) {
    const n = entity(body, k)?.notes;
    if (n && typeof n === 'object' && Object.keys(n).length) return n as Notes;
  }
  return undefined;
}

/**
 * How many credits a captured amount buys, at OUR rate.
 *
 * Never the body's idea of how many credits to give: the body is written by
 * whoever created the payment link. Rounded DOWN — the shop is never given a
 * credit it has not paid for, and the remainder stays on the top-up record as
 * the amount actually paid, so the arithmetic can be checked later.
 */
export function creditsFor(amountPaise: number, ratePaise: number): number {
  if (!Number.isFinite(amountPaise) || !Number.isFinite(ratePaise)) return 0;
  if (amountPaise <= 0 || ratePaise <= 0) return 0;
  return Math.floor(amountPaise / ratePaise);
}
