import { createClient, type PostgrestError } from '@supabase/supabase-js';
import { getConnection } from '@/lib/config';
import { enqueueOutbox, isNetworkError, isOnline, OfflineQueuedError, outboxItems, removeOutboxItem, updateOutboxItem } from '@/lib/offline';
import { assertWritable } from '@/lib/readonly';
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

/**
 * A document's lines in the order they were typed — on a database that may not
 * have been given db/55 yet.
 *
 * The SQL is applied by hand in the Supabase editor; the front end deploys the
 * moment a commit lands. So there is always a window where the app is ahead of
 * the schema, and asking for a column that is not there yet is a 400 that kills
 * the screen outright. It did: every purchase view, edit and print stopped
 * working between the deploy and the migration being run.
 *
 * Postgres calls that 42703, undefined_column, and it is the one failure worth
 * recovering from here — the query without the new ordering is exactly what the
 * screen did last week. Showing the old order for an afternoon is a nuisance; a
 * dead screen is not. Everything else is thrown as it always was.
 */
export async function expectRowsOrUnordered<R>(
  run: (byLineNo: boolean) => PromiseLike<RowsResult<R>>,
): Promise<R[]> {
  const first = await run(true);
  if (!first.error) return first.data ?? [];
  if (first.error.code !== '42703') throw first.error;
  return expectRows(run(false));
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
  // A lapsed licence must not reach the outbox either: queued, it would look
  // to the shop like a bill that will go through once the connection is back.
  assertWritable();
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
/**
 * Every `supabase.from(x).insert/update/delete/upsert` in the app, gated in one
 * place. The masters — items, customers, suppliers, rates — do not go through
 * the document tables the database guards, so without this a frozen shop could
 * still add products all day.
 */
function freezeWrites<T extends { from: (t: never) => unknown }>(client: T): T {
  const original = client.from.bind(client) as (t: never) => Record<string, unknown>;
  const guarded = (table: never) => {
    const builder = original(table);
    for (const method of ['insert', 'update', 'delete', 'upsert'] as const) {
      const real = builder[method];
      if (typeof real !== 'function') continue;
      builder[method] = (...args: unknown[]) => {
        assertWritable();
        return (real as (...a: unknown[]) => unknown).apply(builder, args);
      };
    }
    return builder;
  };
  (client as { from: unknown }).from = guarded;
  return client;
}

export const supabase = freezeWrites(createClient<Database>(
  connection?.url ?? 'http://localhost:54321',
  connection?.anonKey ?? 'missing-anon-key',
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  },
));
