// Supabase Edge Function: backup-org
//
// Takes an org snapshot (org_snapshot() in db/17_owner.sql), stores it as JSON in the
// private `backups` bucket under <org_id>/<timestamp>.json, records it in `backups`,
// and prunes copies beyond the org's keep_copies.
//
// Called two ways:
//   - by pg_cron every hour with the service role (db/cron/schedule.sql): every org
//     that backups_due() says has reached its run hour is backed up (is_auto = true)
//   - by the owner from Setup → Backup ("Back up now") for their own org
//
//   supabase functions deploy backup-org
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

interface Result { org_id: string; backup_id?: string; file_path?: string; size_bytes?: number; pruned?: number; error?: string }

async function backupOrg(admin: SupabaseClient, orgId: string, isAuto: boolean, keepCopies: number, createdBy: string | null): Promise<Result> {
  const { data: row, error: rowError } = await admin.from('backups').insert({ org_id: orgId, is_auto: isAuto, status: 'running', created_by: createdBy }).select('id').single();
  if (rowError || !row) return { org_id: orgId, error: rowError?.message ?? 'Could not record the backup' };
  const backupId = row.id as string;
  try {
    const { data: snapshot, error: snapError } = await admin.rpc('org_snapshot', { p_org: orgId });
    if (snapError) throw new Error(snapError.message);
    const body = JSON.stringify(snapshot);
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const filePath = `${orgId}/${stamp}.json`;
    const { error: upError } = await admin.storage.from('backups').upload(filePath, new Blob([body], { type: 'application/json' }), { contentType: 'application/json', upsert: false });
    if (upError) throw new Error(upError.message);
    const size = new TextEncoder().encode(body).length;
    await admin.from('backups').update({ status: 'ready', file_path: filePath, size_bytes: size }).eq('id', backupId);

    // retention: keep the newest N ready copies (manual and automatic alike)
    let pruned = 0;
    const { data: old } = await admin.from('backups').select('id, file_path').eq('org_id', orgId).eq('status', 'ready').order('created_at', { ascending: false }).range(Math.max(keepCopies, 1), 10_000);
    for (const b of old ?? []) {
      if (b.file_path) await admin.storage.from('backups').remove([b.file_path as string]);
      await admin.from('backups').delete().eq('id', b.id);
      pruned += 1;
    }
    return { org_id: orgId, backup_id: backupId, file_path: filePath, size_bytes: size, pruned };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await admin.from('backups').update({ status: 'failed' }).eq('id', backupId);
    return { org_id: orgId, backup_id: backupId, error: message };
  }
}

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

  if (token === serviceKey) {
    // scheduler: whoever is due this hour
    const { data: due, error } = await admin.rpc('backups_due');
    if (error) return json({ error: error.message }, 500);
    const results: Result[] = [];
    for (const d of due ?? []) results.push(await backupOrg(admin, d.org_id as string, true, Number(d.keep_copies ?? 30), null));
    return json({ results });
  }

  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: me } = await caller.from('v_me').select('org_id, staff_id, role, is_active').maybeSingle();
  if (!me || !me.is_active || !me.org_id) return json({ error: 'Not a member of any organisation' }, 403);
  if (me.role !== 'owner') return json({ error: 'Only the owner can take a backup' }, 403);
  const { data: settings } = await admin.from('backup_settings').select('keep_copies').eq('org_id', me.org_id).maybeSingle();
  const result = await backupOrg(admin, me.org_id as string, false, Number(settings?.keep_copies ?? 30), me.staff_id as string);
  return json(result, result.error ? 500 : 200);
});
