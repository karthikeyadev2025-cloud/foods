import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * A half-typed document, kept on this machine until it is saved.
 *
 * "The in-progress bill should be preserved even when the user temporarily
 * switches tabs/windows or leaves the screen midway."
 *
 * Tab-switching is fixed at its root (src/features/auth/session.ts) — the screen
 * no longer unmounts. This is for everything else: walking away and clicking
 * Customers, the browser being closed, a crash, a deploy reloading the page. A
 * bill with fifteen lines on it is fifteen minutes of somebody's afternoon, and
 * none of it is on the server until Save.
 *
 * localStorage, not the server: it must survive with no connection, and a draft
 * is nobody else's business — it is not a document until it is saved.
 */
const PREFIX = 'jf:draft:';

/**
 * How long a draft is worth restoring. Long enough for a bill left over lunch
 * or overnight; short enough that last week's abandoned attempt does not come
 * back to haunt a fresh screen.
 */
const KEEP_MS = 2 * 24 * 60 * 60 * 1000;

interface Stored<T> {
  at: number;
  value: T;
}

function storageKey(name: string, scope: string | null | undefined): string {
  // Scoped to the signed-in user: a shared counter machine must never hand one
  // operator's half-typed bill to the next.
  return `${PREFIX}${scope ?? 'anon'}:${name}`;
}

/** Read a draft, if one is there and still fresh. Never throws. */
export function readDraft<T>(name: string, scope: string | null | undefined): { value: T; at: number } | null {
  try {
    const raw = localStorage.getItem(storageKey(name, scope));
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Stored<T>;
    if (!parsed || typeof parsed.at !== 'number') return null;
    if (Date.now() - parsed.at > KEEP_MS) {
      localStorage.removeItem(storageKey(name, scope));
      return null;
    }
    return { value: parsed.value, at: parsed.at };
  } catch {
    // Private windows, a full disk, a half-written entry from a crash. A draft
    // that cannot be read is simply not there; it must never break the screen.
    return null;
  }
}

export function clearDraft(name: string, scope: string | null | undefined): void {
  try {
    localStorage.removeItem(storageKey(name, scope));
  } catch {
    /* nothing to do */
  }
}

/**
 * Keep `value` on disk while it is worth keeping.
 *
 * `worthKeeping` decides that: an untouched screen must not leave a draft
 * behind, or every visit to New bill would offer to restore an empty one.
 * Writes are debounced, because this runs on every keystroke.
 */
export function useDraft<T>(
  name: string,
  scope: string | null | undefined,
  value: T,
  worthKeeping: (v: T) => boolean,
  enabled = true,
): { clear: () => void } {
  const latest = useRef(value);
  latest.current = value;
  // Keyed on the CONTENT, not the object. A form's watch() hands back a fresh
  // object every render, so depending on its identity would restart the debounce
  // on renders that changed nothing at all.
  const json = JSON.stringify(value);

  useEffect(() => {
    if (!enabled) return;
    const id = setTimeout(() => {
      try {
        if (worthKeeping(latest.current)) {
          localStorage.setItem(storageKey(name, scope), JSON.stringify({ at: Date.now(), value: JSON.parse(json) } satisfies Stored<T>));
        } else {
          localStorage.removeItem(storageKey(name, scope));
        }
      } catch {
        /* a draft that cannot be written is a lost draft, never a broken screen */
      }
    }, 400);
    return () => clearTimeout(id);
    // worthKeeping is a plain predicate; re-running on its identity would write
    // on every render for no reason.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [name, scope, json, enabled]);

  return { clear: useCallback(() => clearDraft(name, scope), [name, scope]) };
}

/**
 * The draft that was on disk when this screen opened, read once.
 *
 * Read in a lazy initialiser rather than an effect so the screen can restore on
 * its very first render — a flash of an empty bill that then fills itself in
 * looks like the bug this was written to fix.
 */
export function useRestoredDraft<T>(name: string, scope: string | null | undefined, enabled = true) {
  const [restored] = useState(() => (enabled ? readDraft<T>(name, scope) : null));
  return restored;
}
