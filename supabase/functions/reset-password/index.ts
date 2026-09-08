// Supabase Edge Function: reset-password
//
// Sets a new password on a staff member's login. Needs the service role, hence a
// function. The owner may reset anyone in the org; an admin may reset anyone except
// owners and admins; nobody resets their own here (use the sign-in screen for that).
//
//   supabase functions deploy reset-password
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
  if (me.role !== 'owner' && me.role !== 'admin') return json({ error: 'Only an owner or admin can reset passwords' }, 403);

  let body: { staff_id?: string; password?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }
  const password = String(body.password ?? '');
  if (!body.staff_id) return json({ error: 'staff_id is required' }, 400);
  if (password.length < 8) return json({ error: 'Password must be at least 8 characters' }, 400);
  if (body.staff_id === me.staff_id) return json({ error: 'Change your own password from the sign-in screen' }, 400);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: staff } = await admin.from('staff').select('id, org_id, auth_uid, role').eq('id', body.staff_id).maybeSingle();
  if (!staff || staff.org_id !== me.org_id) return json({ error: 'User not found' }, 404);
  if (me.role === 'admin' && (staff.role === 'owner' || staff.role === 'admin')) return json({ error: 'An admin cannot reset an owner or admin' }, 403);
  if (!staff.auth_uid) return json({ error: 'This user has no login yet' }, 400);

  const { error } = await admin.auth.admin.updateUserById(staff.auth_uid as string, { password });
  if (error) return json({ error: error.message }, 400);
  return json({ ok: true });
});
