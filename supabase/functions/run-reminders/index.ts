// Supabase Edge Function: run-reminders
//
// Runs every active reminder rule (the escalation ladder) and then drains the queue.
// Called by pg_cron (db/cron/schedule.sql) with the service role, or from the app by a
// user with Messaging edit rights for their own org ("Run reminders now").
//
//   supabase functions deploy run-reminders
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

  let orgId: string | null = null;
  if (token !== serviceKey) {
    const caller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
    const { data: me } = await caller.from('v_me').select('org_id, is_active').maybeSingle();
    if (!me || !me.is_active || !me.org_id) return json({ error: 'Not a member of any organisation' }, 403);
    const { data: allowed } = await caller.rpc('can_edit', { p_module: 'messaging' });
    if (!allowed) return json({ error: 'Messaging edit rights are needed' }, 403);
    orgId = me.org_id as string;
  }

  const { data: runs, error } = await admin.rpc('run_reminders', { p_org: orgId ?? undefined });
  if (error) return json({ error: error.message }, 500);

  const orgIds = orgId ? [orgId] : (await admin.from('messaging_settings').select('org_id').eq('is_enabled', true)).data?.map((r) => r.org_id as string) ?? [];
  const sends = [];
  for (const id of orgIds) {
    try {
      sends.push(await drainOrg(admin, id));
    } catch (e) {
      sends.push({ org_id: id, claimed: 0, sent: 0, failed: 0, skipped_reason: e instanceof Error ? e.message : String(e) });
    }
  }
  return json({ runs, sends });
});
