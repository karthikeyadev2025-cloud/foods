// Supabase Edge Function: razorpay-credits
//
// Razorpay calls this when a shop pays for message credits — a payment link, a
// per-shop QR code, or a card payment. It turns the payment into credits.
//
// This function hands out something that costs money, from a request anyone on
// the internet can send. Three things stand between the two, and none of them
// may be skipped:
//
//   1. THE SIGNATURE. Razorpay signs the exact bytes of the body with the
//      webhook secret. Nothing in the body is read, parsed or trusted before
//      that signature has been checked against those bytes — a forged
//      "payment.captured" is otherwise free credits for the asking. The
//      comparison is byte-by-byte over the whole digest so a wrong signature
//      tells the sender nothing about how wrong it was.
//
//   2. THE RATE IS OURS, NOT THEIRS. Credits are the amount Razorpay says was
//      actually captured, divided by the rate held in this function's own
//      secrets. The body is never asked how many credits to give, because the
//      body is written by whoever made the payment link.
//
//   3. THE PAYMENT ID. Razorpay retries a webhook until it gets a 200, and
//      will send the same payment again. add_credits is idempotent on the
//      payment id, so a retry adds nothing rather than minting credits every
//      time the network hiccups.
//
// Which shop paid is read from the payment notes — the supplier creates one
// payment link or QR per shop with notes.org_id (or notes.license_key) set. A
// payment that says nothing about the shop is PARKED, not dropped, and still
// answered 200 so Razorpay stops retrying something already recorded; the
// supplier attributes it by hand with assign_unmatched_payment.
//
// Secrets this function needs:
//   RAZORPAY_WEBHOOK_SECRET    the secret set on the webhook in the Razorpay dashboard
//   RAZORPAY_PAISE_PER_CREDIT  what one credit costs, in paise (90 = 90 paise)
//
//   supabase functions deploy razorpay-credits --no-verify-jwt
import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

import { creditsFor, notesOf, paymentOf, sameDigest, signBody } from '../_shared/razorpay.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const secret = Deno.env.get('RAZORPAY_WEBHOOK_SECRET');
  if (!url || !serviceKey) return json({ error: 'Function secrets are not configured' }, 500);
  // Without the secret there is no way to tell a real payment from a made-up
  // one, so nothing is accepted at all. Refusing every payment is recoverable;
  // accepting a forged one is not.
  if (!secret) return json({ error: 'RAZORPAY_WEBHOOK_SECRET is not set' }, 500);

  const rate = Number(Deno.env.get('RAZORPAY_PAISE_PER_CREDIT') ?? '90');
  if (!Number.isFinite(rate) || rate <= 0) return json({ error: 'RAZORPAY_PAISE_PER_CREDIT is not a number of paise' }, 500);

  // The RAW bytes, before any parsing: the signature covers these exactly, and
  // JSON.parse followed by JSON.stringify would not give them back.
  const raw = await req.text();
  const given = req.headers.get('x-razorpay-signature') ?? '';
  if (!given || !sameDigest(given, await signBody(secret, raw))) {
    return json({ error: 'Signature does not match' }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }

  const event = String(body.event ?? '');
  const payment = paymentOf(body);
  // Only money actually captured buys credits. An authorized-but-not-captured
  // payment can still fail, and a refund or dispute is money going back.
  const captured = payment && String(payment.status ?? '') === 'captured';
  if (!captured) return json({ ignored: event, reason: 'no captured payment in this event' });

  const paymentId = String(payment.id ?? '');
  const amountPaise = Number(payment.amount ?? 0);
  if (!paymentId || !Number.isFinite(amountPaise) || amountPaise <= 0) {
    return json({ ignored: event, reason: 'no payment id or amount' });
  }

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const notes = notesOf(body);

  // Which shop. The id if it is there, otherwise the licence key — never a
  // name, which two shops can share.
  let orgId: string | null = null;
  const noteOrg = String((notes?.org_id ?? notes?.orgId ?? '') as string).trim();
  if (UUID.test(noteOrg)) {
    const { data } = await admin.from('orgs').select('id').eq('id', noteOrg).maybeSingle();
    orgId = data?.id ?? null;
  }
  if (!orgId) {
    const key = String((notes?.license_key ?? notes?.licence_key ?? '') as string).trim();
    if (key) {
      const { data } = await admin.from('orgs').select('id').eq('license_key', key).maybeSingle();
      orgId = data?.id ?? null;
    }
  }

  if (!orgId) {
    // Park it. The money is real and recorded; only its owner is unknown.
    const { error } = await admin.from('credit_payments_unmatched').upsert(
      { provider: 'razorpay', payment_id: paymentId, amount_paise: amountPaise, payload: body },
      { onConflict: 'provider,payment_id', ignoreDuplicates: true },
    );
    if (error) return json({ error: error.message }, 500);
    return json({ parked: true, payment_id: paymentId, amount_paise: amountPaise, reason: 'the payment does not say which shop it is for' });
  }

  const credits = creditsFor(amountPaise, rate);
  if (credits <= 0) {
    return json({ ignored: event, reason: `Rs ${(amountPaise / 100).toFixed(2)} does not buy a credit at ${rate} paise` });
  }

  const { data, error } = await admin.rpc('add_credits', {
    p_org: orgId,
    p_credits: credits,
    p_amount_paise: amountPaise,
    p_payment_id: paymentId,
    p_order_id: payment.order_id ? String(payment.order_id) : undefined,
    p_provider: 'razorpay',
    p_note: String((notes?.note ?? '') as string) || undefined,
  });
  if (error) return json({ error: error.message }, 500);

  return json({ ok: true, event, payment_id: paymentId, ...(data as Record<string, unknown>) });
});
