// Supabase Edge Function: nikki-send
//
// Sends whatever the queue allows right now. Two callers:
//   • the app (a signed-in user with Messaging edit rights) after queueing something —
//     "Send now" — for their own org;
//   • pg_cron / the service role, every few minutes, for every org (body {} or {org_id}).
//
//   supabase functions deploy nikki-send
//   supabase secrets set ... (SUPABASE_* are injected automatically)
import { createClient } from 'npm:@supabase/supabase-js@2';
import { drainOrg } from '../_shared/send.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  const url = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anonKey || !serviceKey) return json({ error: 'Function secrets are not configured' }, 500);

  const authHeader = req.headers.get('Authorization') ?? '';
  const token = authHeader.replace(/^Bearer\s+/i, '');
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // empty body is fine
  }

  let orgIds: string[] = [];
  if (token === serviceKey) {
    // Scheduled drain: every org with messaging on, or the one named.
    if (body.org_id) orgIds = [String(body.org_id)];
    else {
      const { data } = await admin.from('messaging_settings').select('org_id').eq('is_enabled', true);
      orgIds = (data ?? []).map((r) => r.org_id as string);
    }
  } else {
    const caller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
    const { data: me, error } = await caller.from('v_me').select('org_id, is_active').maybeSingle();
    if (error) return json({ error: error.message }, 500);
    if (!me || !me.is_active || !me.org_id) return json({ error: 'Not a member of any organisation' }, 403);
    const { data: allowed } = await caller.rpc('can_edit', { p_module: 'messaging' });
    if (!allowed) return json({ error: 'Messaging edit rights are needed to send' }, 403);
    orgIds = [me.org_id as string];
  }

  const results = [];
  for (const orgId of orgIds) {
    try {
      results.push(await drainOrg(admin, orgId, Number(body.limit ?? 50)));
    } catch (e) {
      results.push({ org_id: orgId, claimed: 0, sent: 0, failed: 0, skipped_reason: e instanceof Error ? e.message : String(e) });
    }
  }
  return json({ results });
});
