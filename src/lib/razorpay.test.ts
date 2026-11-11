import { describe, expect, it } from 'vitest';
import { creditsFor, notesOf, paymentOf, sameDigest, signBody } from '../../supabase/functions/_shared/razorpay.ts';

/**
 * The credits webhook hands out money from a request anyone can send. These
 * are the tests for the part that decides whether to believe the request.
 */
const SECRET = 'whsec_test_123';

const captured = (over: Record<string, unknown> = {}) => ({
  event: 'payment.captured',
  payload: { payment: { entity: { id: 'pay_LIVE1', status: 'captured', amount: 90000, ...over } } },
});

describe('the signature', () => {
  it('matches the signature Razorpay would send for the same bytes', async () => {
    const raw = JSON.stringify(captured());
    expect(sameDigest(await signBody(SECRET, raw), await signBody(SECRET, raw))).toBe(true);
  });

  it('refuses a body that was changed after it was signed', async () => {
    const raw = JSON.stringify(captured());
    const sig = await signBody(SECRET, raw);
    // the amount talked up from 900 rupees to 90,000
    const tampered = raw.replace('"amount":90000', '"amount":9000000');
    expect(sameDigest(sig, await signBody(SECRET, tampered))).toBe(false);
  });

  it('refuses a signature made with the wrong secret', async () => {
    const raw = JSON.stringify(captured());
    expect(sameDigest(await signBody('whsec_guess', raw), await signBody(SECRET, raw))).toBe(false);
  });

  it('refuses an empty or truncated signature rather than matching a prefix', async () => {
    const real = await signBody(SECRET, JSON.stringify(captured()));
    expect(sameDigest('', real)).toBe(false);
    expect(sameDigest(real.slice(0, 32), real)).toBe(false);
    expect(sameDigest(real + '00', real)).toBe(false);
  });

  it('signs the raw bytes, so re-serialising the parsed body is not the same thing', async () => {
    // Razorpay's body is not necessarily the shortest spelling of that JSON.
    const raw = '{"event":"payment.captured", "payload":{}}';
    const resaved = JSON.stringify(JSON.parse(raw));
    expect(raw).not.toBe(resaved);
    expect(await signBody(SECRET, raw)).not.toBe(await signBody(SECRET, resaved));
  });
});

describe('what the event says', () => {
  it('finds the payment in a plain payment event', () => {
    expect(paymentOf(captured())?.id).toBe('pay_LIVE1');
  });

  it('finds the payment in a QR code credit', () => {
    const body = {
      event: 'qr_code.credited',
      payload: {
        qr_code: { entity: { id: 'qr_1', notes: { org_id: 'a' } } },
        payment: { entity: { id: 'pay_QR', status: 'captured', amount: 45000 } },
      },
    };
    expect(paymentOf(body)?.id).toBe('pay_QR');
  });

  it('finds no payment in an event that carries none', () => {
    expect(paymentOf({ event: 'order.paid', payload: { order: { entity: { id: 'order_1' } } } })).toBeNull();
    expect(paymentOf({ event: 'subscription.charged' })).toBeNull();
    expect(paymentOf({})).toBeNull();
  });

  it('reads the notes off the payment first', () => {
    const body = {
      payload: {
        payment: { entity: { id: 'p', notes: { org_id: 'from-payment' } } },
        order: { entity: { notes: { org_id: 'from-order' } } },
      },
    };
    expect(notesOf(body)?.org_id).toBe('from-payment');
  });

  it('falls back to the order, the link, then the QR code', () => {
    expect(notesOf({ payload: { payment: { entity: { id: 'p' } }, order: { entity: { notes: { org_id: 'o' } } } } })?.org_id).toBe('o');
    expect(notesOf({ payload: { payment_link: { entity: { notes: { org_id: 'l' } } } } })?.org_id).toBe('l');
    expect(notesOf({ payload: { qr_code: { entity: { notes: { org_id: 'q' } } } } })?.org_id).toBe('q');
  });

  it('treats empty notes as no notes, so the payment is parked and not given away', () => {
    expect(notesOf({ payload: { payment: { entity: { id: 'p', notes: {} } } } })).toBeUndefined();
    expect(notesOf({})).toBeUndefined();
  });
});

describe('how many credits the money buys', () => {
  it('is the amount captured divided by our rate', () => {
    expect(creditsFor(90000, 90)).toBe(1000); // 900 rupees at 90 paise
    expect(creditsFor(45000, 90)).toBe(500);
  });

  it('rounds down, so a shop never gets a credit it has not paid for', () => {
    expect(creditsFor(100, 90)).toBe(1);
    expect(creditsFor(179, 90)).toBe(1);
    expect(creditsFor(89, 90)).toBe(0);
  });

  it('gives nothing for nothing, and nothing for nonsense', () => {
    expect(creditsFor(0, 90)).toBe(0);
    expect(creditsFor(-90000, 90)).toBe(0);
    expect(creditsFor(90000, 0)).toBe(0);
    expect(creditsFor(90000, -90)).toBe(0);
    expect(creditsFor(Number.NaN, 90)).toBe(0);
    expect(creditsFor(Number.POSITIVE_INFINITY, 90)).toBe(0);
  });

  it('is the rate we hold, never a count sent in the body', () => {
    // A payment link whose notes claim a million credits for 1 rupee buys
    // exactly what 1 rupee buys.
    const body = { payload: { payment: { entity: { id: 'p', status: 'captured', amount: 100, notes: { credits: '1000000' } } } } };
    const p = paymentOf(body)!;
    expect(creditsFor(Number(p.amount), 90)).toBe(1);
  });
});
