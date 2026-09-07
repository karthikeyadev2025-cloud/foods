// Supabase Edge Function: create-user
//
// Creates an auth login + staff row for the caller's org. Needs the service
// role key, which must never reach the browser — hence a function.
//
//   supabase functions deploy create-user
//
// Gate: caller must be an active owner/admin (read through v_me under the
// caller's own JWT, so RLS decides). Admins may not create owners or admins.
import { createClient } from 'npm:@supabase/supabase-js@2';

const ROLES = ['owner', 'admin', 'accountant', 'store_keeper', 'production_head', 'chief', 'driver', 'sales_exec'];

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  const url = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anonKey || !serviceKey) return json({ error: 'Function secrets are not configured' }, 500);

  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return json({ error: 'Not signed in' }, 401);

  // Who is calling? Same RLS as the app.
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: me, error: meError } = await caller.from('v_me').select('*').maybeSingle();
  if (meError) return json({ error: meError.message }, 500);
  if (!me || !me.is_active) return json({ error: 'Not a member of any organisation' }, 403);
  if (me.role !== 'owner' && me.role !== 'admin') return json({ error: 'Only an owner or admin can create users' }, 403);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }

  const email = String(body.email ?? '').trim().toLowerCase();
  const password = String(body.password ?? '');
  const full_name = String(body.full_name ?? '').trim();
  const phone = body.phone ? String(body.phone).trim() : null;
  const role = String(body.role ?? '');
  const is_mestry = Boolean(body.is_mestry);
  const daily_wage = Number(body.daily_wage ?? 0);

  if (!email || !email.includes('@')) return json({ error: 'A valid email is required' }, 400);
  if (password.length < 8) return json({ error: 'Password must be at least 8 characters' }, 400);
  if (!full_name) return json({ error: 'Full name is required' }, 400);
  if (!ROLES.includes(role)) return json({ error: `Unknown role ${role}` }, 400);
  if (me.role === 'admin' && (role === 'owner' || role === 'admin')) {
    return json({ error: 'An admin cannot create owners or admins' }, 403);
  }
  if (!Number.isFinite(daily_wage) || daily_wage < 0) return json({ error: 'Daily wage must be zero or more' }, 400);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name },
  });
  if (createError || !created.user) return json({ error: createError?.message ?? 'Could not create login' }, 400);

  const { data: staff, error: staffError } = await admin
    .from('staff')
    .insert({
      org_id: me.org_id,
      auth_uid: created.user.id,
      full_name,
      phone,
      role,
      is_mestry,
      daily_wage,
    })
    .select('*')
    .single();

  if (staffError) {
    // Do not leave an orphan login behind.
    await admin.auth.admin.deleteUser(created.user.id);
    return json({ error: staffError.message }, 400);
  }

  return json({ staff });
});
