import { createStore, del, entries, set } from 'idb-keyval';

/**
 * Offline support (T11.3).
 *
 *  - reads: TanStack Query's cache is persisted to IndexedDB (app/providers.tsx), so
 *    every screen already opened shows its last data without a connection
 *  - writes: a document saved while offline goes to the OUTBOX below and is replayed,
 *    in order, when the connection is back (lib/supabase.ts replayOutbox)
 *
 * The outbox holds RPC calls exactly as the api.ts would have made them.
 */

export interface OutboxItem {
  id: string;
  /** RPC name, e.g. save_invoice. */
  fn: string;
  args: Record<string, unknown>;
  /** What the user sees: "Invoice for P. SRINIVAS". */
  label: string;
  created_at: string;
  attempts: number;
  /** Last non-network error; the item waits for the user to retry or discard. */
  error?: string;
}

/** Thrown by queuedRpc when the call was put in the outbox instead of being sent. */
export class OfflineQueuedError extends Error {
  constructor(public readonly label: string) {
    super(`${label} saved to the outbox`);
    this.name = 'OfflineQueuedError';
  }
}

export function isOnline(): boolean {
  // Node (tests) has a navigator without onLine; treat that as connected.
  return typeof navigator === 'undefined' || typeof navigator.onLine !== 'boolean' ? true : navigator.onLine;
}

/** A failed fetch (no connection, DNS, server unreachable) rather than a business error. */
export function isNetworkError(err: unknown): boolean {
  if (!isOnline()) return true;
  const message = (err instanceof Error ? err.message : typeof err === 'object' && err !== null && 'message' in err ? String((err as { message: unknown }).message) : String(err)).toLowerCase();
  return /failed to fetch|networkerror|network request failed|load failed|fetch failed|econnrefused|enotfound|timed? ?out/.test(message);
}

// ---------------------------------------------------------------- store
const store = typeof indexedDB === 'undefined' ? null : createStore('erp-outbox', 'items');
let items: OutboxItem[] = [];
let loaded = false;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach((l) => l());

export async function loadOutbox(): Promise<OutboxItem[]> {
  if (!store) {
    loaded = true;
    return items;
  }
  try {
    const rows = await entries<string, OutboxItem>(store);
    items = rows.map(([, v]) => v).sort((a, b) => a.created_at.localeCompare(b.created_at));
  } catch {
    items = [];
  }
  loaded = true;
  notify();
  return items;
}

export function outboxItems(): OutboxItem[] {
  return items;
}
export function outboxLoaded(): boolean {
  return loaded;
}
export function subscribeOutbox(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export async function enqueueOutbox(input: { fn: string; args: Record<string, unknown>; label: string }): Promise<OutboxItem> {
  const item: OutboxItem = { id: crypto.randomUUID(), fn: input.fn, args: input.args, label: input.label, created_at: new Date().toISOString(), attempts: 0 };
  items = [...items, item];
  if (store) await set(item.id, item, store);
  notify();
  return item;
}

export async function updateOutboxItem(id: string, patch: Partial<OutboxItem>): Promise<void> {
  items = items.map((i) => (i.id === id ? { ...i, ...patch } : i));
  const item = items.find((i) => i.id === id);
  if (store && item) await set(id, item, store);
  notify();
}

export async function removeOutboxItem(id: string): Promise<void> {
  items = items.filter((i) => i.id !== id);
  if (store) await del(id, store);
  notify();
}

// ---------------------------------------------------------------- connection
const onlineListeners = new Set<() => void>();
if (typeof window !== 'undefined') {
  window.addEventListener('online', () => onlineListeners.forEach((l) => l()));
  window.addEventListener('offline', () => onlineListeners.forEach((l) => l()));
}
export function subscribeOnline(listener: () => void): () => void {
  onlineListeners.add(listener);
  return () => onlineListeners.delete(listener);
}
