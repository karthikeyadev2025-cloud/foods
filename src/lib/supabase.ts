import { createClient, type PostgrestError } from '@supabase/supabase-js';
import { getConnection } from '@/lib/config';
import { enqueueOutbox, isNetworkError, isOnline, OfflineQueuedError, outboxItems, removeOutboxItem, updateOutboxItem } from '@/lib/offline';
import type { Database } from '@/types/supabase';

type Fns = Database['public']['Functions'];

interface RowsResult<R> {
  data: R[] | null;
  error: PostgrestError | null;
}
interface OneResult<R> {
  data: R | null;
  error: PostgrestError | null;
}
interface OkResult {
  error: PostgrestError | null;
}

/** Await a list query; throw its PostgrestError (code included) instead of returning it. */
export async function expectRows<R>(query: PromiseLike<RowsResult<R>>): Promise<R[]> {
  const { data, error } = await query;
  if (error) throw error;
  return data ?? [];
}

/** Await a `.single()` query and require a row. */
export async function expectOne<R>(query: PromiseLike<OneResult<R>>): Promise<R> {
  const { data, error } = await query;
  if (error) throw error;
  if (data === null) throw new Error('Expected a row, got none');
  return data;
}

/** Await a write with no result rows. */
export async function expectOk(query: PromiseLike<OkResult>): Promise<void> {
  const { error } = await query;
  if (error) throw error;
}

/**
 * A document-creating RPC that survives a dead connection: offline (or when the
 * fetch itself fails) the call is put in the outbox and OfflineQueuedError is thrown,
 * which toastError shows as "saved to the outbox". Business errors throw as usual.
 */
export async function queuedRpc<N extends keyof Fns & string>(name: N, args: Fns[N]['Args'], label: string): Promise<Fns[N]['Returns']> {
  const params = args as Record<string, unknown>;
  if (!isOnline()) {
    await enqueueOutbox({ fn: name, args: params, label });
    throw new OfflineQueuedError(label);
  }
  const { data, error } = await rawRpc(name, params);
  if (error) {
    if (isNetworkError(error)) {
      await enqueueOutbox({ fn: name, args: params, label });
      throw new OfflineQueuedError(label);
    }
    throw error;
  }
  return data as Fns[N]['Returns'];
}

export interface ReplayResult {
  sent: number;
  failed: number;
  /** True when a network error stopped the run; the rest stays queued. */
  stopped: boolean;
}

let replaying: Promise<ReplayResult> | null = null;

/** Send the outbox in order. Business errors stay on the item; a network error stops the run. */
export function replayOutbox(): Promise<ReplayResult> {
  if (replaying) return replaying;
  replaying = (async () => {
    const result: ReplayResult = { sent: 0, failed: 0, stopped: false };
    for (const item of [...outboxItems()]) {
      if (item.error) continue;
      const { error } = await rawRpc(item.fn, item.args);
      if (!error) {
        await removeOutboxItem(item.id);
        result.sent += 1;
      } else if (isNetworkError(error)) {
        await updateOutboxItem(item.id, { attempts: item.attempts + 1 });
        result.stopped = true;
        break;
      } else {
        await updateOutboxItem(item.id, { attempts: item.attempts + 1, error: error.message });
        result.failed += 1;
      }
    }
    return result;
  })().finally(() => {
    replaying = null;
  });
  return replaying;
}

function rawRpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: PostgrestError | null }> {
  return (supabase.rpc as unknown as (f: string, a: Record<string, unknown>) => PromiseLike<{ data: unknown; error: PostgrestError | null }>)(fn, args);
}

const connection = getConnection();

/** True once this copy knows its project — from the build, or from the first-run screen. */
export const isSupabaseConfigured = connection !== null;

/**
 * The single Supabase client. Only `features/<x>/api.ts` files may import this —
 * no `supabase.from()` inside a component, ever (DOMAIN_RULES.md rule 2).
 *
 * Built once at module load: when the connection changes, the app reloads rather than
 * swapping the client under a live cache.
 */
export const supabase = createClient<Database>(
  connection?.url ?? 'http://localhost:54321',
  connection?.anonKey ?? 'missing-anon-key',
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  },
);
