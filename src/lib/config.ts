/**
 * Where this copy of the app finds its database.
 *
 * The web build bakes the project in at build time (`.env` → `VITE_SUPABASE_*`), which
 * is what Vercel does. The desktop installer cannot: one `.exe` is handed to whoever
 * needs it, so on first run it asks for the project address and the anon key and keeps
 * them on that machine. Build-time values always win, so a configured build never asks.
 *
 * The anon key is public by design — every table sits behind row-level security, and a
 * key on its own opens nothing. The service role key must never be typed here.
 */
const STORE_KEY = 'erp.connection';

export interface Connection {
  url: string;
  anonKey: string;
}

function fromEnv(): Connection | null {
  const url = import.meta.env.VITE_SUPABASE_URL;
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;
  return url && anonKey ? { url, anonKey } : null;
}

function fromStore(): Connection | null {
  try {
    const raw = localStorage.getItem(STORE_KEY);
    if (!raw) return null;
    const parsed: unknown = JSON.parse(raw);
    const o = (parsed && typeof parsed === 'object' ? parsed : {}) as Partial<Connection>;
    return o.url && o.anonKey ? { url: o.url, anonKey: o.anonKey } : null;
  } catch {
    return null;
  }
}

/** Build-time first, then what this machine was told on first run. */
export function getConnection(): Connection | null {
  return fromEnv() ?? fromStore();
}

/** True when the connection came from the build, so the screen must not offer to change it. */
export function isBuiltIn(): boolean {
  return fromEnv() !== null;
}

export function saveConnection(c: Connection): void {
  localStorage.setItem(STORE_KEY, JSON.stringify({ url: c.url.replace(/\/+$/, ''), anonKey: c.anonKey.trim() }));
}

export function clearConnection(): void {
  try {
    localStorage.removeItem(STORE_KEY);
  } catch {
    // storage blocked: nothing was stored either
  }
}

/**
 * Ask the project whether the key is good before we keep it, so a typo is caught here
 * rather than as a puzzling sign-in failure later. Returns null when it is fine.
 */
export async function checkConnection(c: Connection): Promise<string | null> {
  const url = c.url.replace(/\/+$/, '');
  if (!/^https:\/\/[^\s/]+/.test(url)) return 'The address should start with https:// — copy it from Supabase → Settings → API.';
  if (c.anonKey.trim().length < 40) return 'That key looks too short. Copy the whole anon public key.';
  if (/service_role/.test(c.anonKey)) return 'That is the service role key. Use the anon public key instead — the service key must never leave the server.';
  let res: Response;
  try {
    res = await fetch(`${url}/rest/v1/`, { headers: { apikey: c.anonKey.trim() } });
  } catch {
    return 'Could not reach that address. Check the internet connection and the address.';
  }
  if (res.status === 401 || res.status === 403) return 'The project answered, but it does not accept that key. Copy the anon public key again.';
  if (!res.ok) return `The project answered with ${res.status}. Check the address is the Project URL from Supabase → Settings → API.`;
  return null;
}
