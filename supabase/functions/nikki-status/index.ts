// Supabase Edge Function: nikki-status
//
// Hey Nikki calls this with delivery updates. Authentication is the org's webhook
// secret (Messaging → Settings) in the X-Nikki-Secret header, or `secret` in the body.
// Accepts one event or an array:
//   { provider_msg_id | message_id, status: sent|delivered|read|failed, error?, at? }
//
//   supabase functions deploy nikki-status --no-verify-jwt
import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const STATUSES = new Set(['sent', 'delivered', 'read', 'failed']);

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) return json({ error: 'Function secrets are not configured' }, 500);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }
  const events = Array.isArray(body) ? body : [body];
  const first = (events[0] ?? {}) as Record<string, unknown>;
  const secret = req.headers.get('x-nikki-secret') ?? String(first.secret ?? '');
  if (!secret) return json({ error: 'Missing webhook secret' }, 401);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: org } = await admin.from('messaging_settings').select('org_id').eq('webhook_secret', secret).maybeSingle();
  if (!org) return json({ error: 'Unknown webhook secret' }, 401);

  let updated = 0;
  const ignored: unknown[] = [];
  for (const raw of events) {
    const e = raw as Record<string, unknown>;
    const id = String(e.provider_msg_id ?? e.message_id ?? e.id ?? '');
    const status = String(e.status ?? '').toLowerCase();
    if (!id || !STATUSES.has(status)) {
      ignored.push(e);
      continue;
    }
    const { data, error } = await admin.rpc('mark_message_status', {
      p_provider_msg_id: id,
      p_status: status,
      p_error: e.error ? String(e.error) : undefined,
      p_at: e.at ? new Date(String(e.at)).toISOString() : undefined,
    });
    if (error) return json({ error: error.message }, 500);
    if (data) updated += 1;
    else ignored.push({ provider_msg_id: id, reason: 'not ours' });
  }
  return json({ updated, ignored: ignored.length });
});
