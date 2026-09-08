// Supabase Edge Function: restore-backup
//
// Puts the owner's org back to a stored snapshot. Reads the JSON from the private
// `backups` bucket and calls restore_org_snapshot() (db/17_owner.sql), which deletes
// what the org owns now and re-inserts the snapshot with triggers off. Staff logins
// and the audit trail survive; the restore itself is written to the audit trail.
//
// Owner only, and only a backup of the caller's own org. The screen asks the owner to
// type the trade name before calling this.
//
//   supabase functions deploy restore-backup
import { createClient } from 'npm:@supabase/supabase-js@2';

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
  if (!authHeader.startsWith('Bearer ')) return json({ error: 'Not signed in' }, 401);
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: me } = await caller.from('v_me').select('org_id, staff_id, role, is_active').maybeSingle();
  if (!me || !me.is_active || !me.org_id) return json({ error: 'Not a member of any organisation' }, 403);
  if (me.role !== 'owner') return json({ error: 'Only the owner can restore' }, 403);

  let body: { backup_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }
  if (!body.backup_id) return json({ error: 'backup_id is required' }, 400);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: backup } = await admin.from('backups').select('id, org_id, file_path, status').eq('id', body.backup_id).maybeSingle();
  if (!backup || backup.org_id !== me.org_id) return json({ error: 'Backup not found' }, 404);
  if (backup.status !== 'ready' && backup.status !== 'restored') return json({ error: `Backup is ${backup.status}` }, 400);
  if (!backup.file_path) return json({ error: 'Backup has no file' }, 400);

  const { data: file, error: dlError } = await admin.storage.from('backups').download(backup.file_path as string);
  if (dlError || !file) return json({ error: dlError?.message ?? 'Could not read the backup file' }, 500);
  let snapshot: { org_id?: string };
  try {
    snapshot = JSON.parse(await file.text());
  } catch {
    return json({ error: 'The backup file is not valid JSON' }, 500);
  }
  if (snapshot.org_id !== me.org_id) return json({ error: 'This backup belongs to another organisation' }, 403);

  // Run as the owner (their JWT) so the audit row names them; the function is a definer.
  const { data, error } = await caller.rpc('restore_org_snapshot', { p: snapshot });
  if (error) return json({ error: error.message }, 500);
  await admin.from('backups').update({ status: 'restored' }).eq('id', backup.id);
  return json(data);
});
