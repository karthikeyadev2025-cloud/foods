// Supabase Edge Function: punchly-sync
//
// Pulls the roster and the punches from Punchly and hands them to the database, which
// folds them into one attendance row per person per day. Called by pg_cron every half
// hour (db/cron/schedule.sql), or from Setup → Attendance by an owner or admin who wants
// it now.
//
// The Punchly key never leaves the server: it lives in punchly_settings, a table no
// signed-in user can read, and only punchly_due() — service role only — hands it out.
//
//   supabase functions deploy punchly-sync
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { chunkRange, PunchlyClient, PunchlyError, type PunchlyPunch } from '../_shared/punchly.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

interface Due {
  org_id: string;
  api_url: string;
  api_key: string;
  from_date: string;
  to_date: string;
  is_backfill: boolean;
  is_reconcile: boolean;
}

interface OrgResult {
  org_id: string;
  staff?: unknown;
  written: number;
  kept_manual: number;
  skipped: number;
  days: string;
  backfill_left?: string | null;
  error?: string;
}

/** One organisation, from its due window to rows in the attendance table. */
async function syncOrg(admin: SupabaseClient, due: Due): Promise<OrgResult> {
  const punchly = new PunchlyClient(due.api_url, due.api_key);
  const out: OrgResult = { org_id: due.org_id, written: 0, kept_manual: 0, skipped: 0, days: `${due.from_date} → ${due.to_date}` };

  // The roster first, so a punch can be traced to a staff row. Punchly's attendance rows
  // carry only staff_id, which the owner may rename; user_id is the stable one, so the
  // codes are turned into user ids here rather than trusted downstream.
  const roster = await punchly.staff();
  const userIdByCode = new Map(roster.map((s) => [s.staff_id, s.user_id]));
  const { data: linked, error: staffErr } = await admin.rpc('upsert_punchly_staff', {
    p_org: due.org_id,
    p_rows: roster.map((s) => ({ user_id: s.user_id, staff_id: s.staff_id, full_name: s.full_name, designation: s.designation ?? null })),
  });
  if (staffErr) throw new Error(staffErr.message);
  out.staff = linked;

  // Then the punches, a chunk at a time, moving the backfill marker as each lands so a
  // run that dies half way resumes instead of starting over.
  for (const span of chunkRange(due.from_date, due.to_date)) {
    const punches: PunchlyPunch[] = await punchly.punches(span.from, span.to);
    const rows = punches.map((p) => ({
      punchly_user_id: userIdByCode.get(p.staff_id) ?? null,
      staff_id: p.staff_id,
      attendance_date: p.attendance_date,
      kind: p.kind,
      occurred_at: p.occurred_at,
      branch_name: p.branch_name ?? null,
      shift_name: p.shift_name ?? null,
      latitude: p.latitude ?? null,
      longitude: p.longitude ?? null,
      enforcement_status: p.enforcement_status ?? 'ok',
    }));
    const { data, error } = await admin.rpc('upsert_punchly_attendance', { p_org: due.org_id, p_rows: rows });
    if (error) throw new Error(error.message);
    const r = data as { written: number; kept_manual: number; skipped: number };
    out.written += r.written;
    out.kept_manual += r.kept_manual;
    out.skipped += r.skipped;
    if (due.is_backfill) {
      const { data: next } = await admin.rpc('punchly_advance', { p_org: due.org_id, p_through: span.to });
      out.backfill_left = (next as string | null) ?? null;
    }
  }
  const what = due.is_backfill ? 'history' : due.is_reconcile ? 'weekly re-check' : 'today and yesterday';
  await admin.rpc('punchly_note', {
    p_org: due.org_id,
    p_note: `${what}, ${out.days}: ${out.written} day${out.written === 1 ? '' : 's'} written, ${out.kept_manual} hand-typed kept`,
    p_ok: true,
    p_reconciled: due.is_reconcile,
  });
  return out;
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

  // pg_cron sweeps every organisation; a person may only sync their own.
  let orgId: string | null = null;
  if (token !== serviceKey) {
    const caller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
    const { data: me } = await caller.from('v_me').select('org_id, role, is_active').maybeSingle();
    if (!me || !me.is_active || !me.org_id) return json({ error: 'Not a member of any organisation' }, 403);
    if (me.role !== 'owner' && me.role !== 'admin') return json({ error: 'Only the owner or an admin can sync attendance' }, 403);
    orgId = me.org_id as string;
  }

  const { data: due, error } = await admin.rpc('punchly_due');
  if (error) return json({ error: error.message }, 500);
  const orgs = ((due ?? []) as Due[]).filter((d) => !orgId || d.org_id === orgId);
  if (!orgs.length) return json({ synced: [], note: 'Punchly is switched off, or no key has been entered.' });

  const synced: OrgResult[] = [];
  for (const d of orgs) {
    try {
      synced.push(await syncOrg(admin, d));
    } catch (e) {
      const note = e instanceof PunchlyError ? e.message : e instanceof Error ? e.message : String(e);
      // The owner reads this on the settings screen, so say what happened and leave
      // last_sync_at alone — an unfinished run must not look like a finished one.
      await admin.rpc('punchly_note', { p_org: d.org_id, p_note: note.slice(0, 500), p_ok: false });
      synced.push({ org_id: d.org_id, written: 0, kept_manual: 0, skipped: 0, days: `${d.from_date} → ${d.to_date}`, error: note });
    }
  }
  return json({ synced });
});
