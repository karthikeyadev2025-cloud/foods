// Supabase Edge Function: nikki-inbound
//
// Hey Nikki posts every inbound WhatsApp message or call transcript here. It becomes a row
// in inbound_orders (status 'new') for an operator to confirm — nothing is invoiced here.
// STOP / START from a known number flips the customer's WhatsApp opt-in.
//
// Body (one message):
//   { from: "+91 98496 86746", text?: "2 box mysoor pak", transcript?: "...", audio_url?: "...",
//     parsed_items?: [{ item_code?, item_name?, qty, uom?, confidence }], source?: "whatsapp"|"call",
//     provider_ref?: "wamid..." }
// Auth: X-Nikki-Secret header (or `secret` in the body) = the org's webhook secret.
//
//   supabase functions deploy nikki-inbound --no-verify-jwt
import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) return json({ error: 'Function secrets are not configured' }, 500);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }
  const secret = req.headers.get('x-nikki-secret') ?? String(body.secret ?? '');
  if (!secret) return json({ error: 'Missing webhook secret' }, 401);
  // An order captured on one of our calls carries our message id as client_ref; the
  // number then comes from that call, so `from` may be absent.
  const clientRef = body.client_ref ?? body.call_ref ?? null;
  if (!body.from && !clientRef) return json({ error: 'from is required' }, 400);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data, error } = await admin.rpc('receive_inbound_order', {
    p: {
      secret,
      from: body.from ? String(body.from) : null,
      text: body.text ?? null,
      transcript: body.transcript ?? null,
      audio_url: body.audio_url ?? body.recording_url ?? null,
      parsed_items: Array.isArray(body.parsed_items) ? body.parsed_items : Array.isArray(body.items) ? body.items : [],
      source: body.source ?? (clientRef ? 'call' : 'whatsapp'),
      provider_ref: body.provider_ref ?? body.message_id ?? body.call_id ?? null,
      confidence: body.confidence ?? null,
      client_ref: clientRef,
      language: body.language ?? null,
      duration: body.duration ?? null,
    },
  });
  if (error) return json({ error: error.message }, error.message === 'Unknown webhook secret' ? 401 : 400);
  return json(data);
});
