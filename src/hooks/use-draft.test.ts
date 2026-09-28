import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { clearDraft, readDraft } from './use-draft';

/**
 * A draft is fifteen minutes of somebody's afternoon. What matters is that it
 * comes back to the right person, does not come back weeks later, and never
 * takes the screen down with it when the browser refuses to cooperate.
 */
const store = new Map<string, string>();

beforeEach(() => {
  store.clear();
  vi.stubGlobal('localStorage', {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

const KEY = 'jf:draft:u1:invoice-new';

describe('readDraft', () => {
  it('gives back what was stored for that user', () => {
    store.set(KEY, JSON.stringify({ at: Date.now(), value: { lines: [1, 2] } }));
    expect(readDraft<{ lines: number[] }>('invoice-new', 'u1')?.value).toEqual({ lines: [1, 2] });
  });

  // A shared counter machine. One operator's half-typed bill must never be
  // handed to whoever signs in next.
  it('never hands one user the draft of another', () => {
    store.set(KEY, JSON.stringify({ at: Date.now(), value: { lines: [1] } }));
    expect(readDraft('invoice-new', 'u2')).toBeNull();
    expect(readDraft('invoice-new', null)).toBeNull();
  });

  it('keeps one left over lunch, and over a night', () => {
    store.set(KEY, JSON.stringify({ at: Date.now() - 20 * 60 * 60 * 1000, value: { lines: [1] } }));
    expect(readDraft('invoice-new', 'u1')).not.toBeNull();
  });

  // Last week's abandoned attempt coming back onto a fresh screen would be
  // worse than losing it.
  it('drops one older than two days, and forgets it for good', () => {
    store.set(KEY, JSON.stringify({ at: Date.now() - 3 * 24 * 60 * 60 * 1000, value: { lines: [1] } }));
    expect(readDraft('invoice-new', 'u1')).toBeNull();
    expect(store.has(KEY)).toBe(false);
  });

  it('reports when it was saved, so the screen can say so', () => {
    const at = Date.now() - 60_000;
    store.set(KEY, JSON.stringify({ at, value: { lines: [] } }));
    expect(readDraft('invoice-new', 'u1')?.at).toBe(at);
  });

  it('says there is nothing rather than throwing on a half-written entry', () => {
    store.set(KEY, '{"at":');
    expect(readDraft('invoice-new', 'u1')).toBeNull();
    store.set(KEY, JSON.stringify({ value: { lines: [1] } }));
    expect(readDraft('invoice-new', 'u1')).toBeNull();
  });

  // A private window, a full disk, site data blocked. The bill screen has to
  // open regardless — losing the draft is a nuisance, a dead screen is not.
  it('survives a browser that refuses to store anything at all', () => {
    vi.stubGlobal('localStorage', {
      getItem: () => { throw new Error('denied'); },
      setItem: () => { throw new Error('denied'); },
      removeItem: () => { throw new Error('denied'); },
    });
    expect(() => readDraft('invoice-new', 'u1')).not.toThrow();
    expect(readDraft('invoice-new', 'u1')).toBeNull();
    expect(() => clearDraft('invoice-new', 'u1')).not.toThrow();
  });
});

describe('clearDraft', () => {
  it('removes only that user\'s draft of that screen', () => {
    store.set(KEY, JSON.stringify({ at: Date.now(), value: 1 }));
    store.set('jf:draft:u1:purchase-new', JSON.stringify({ at: Date.now(), value: 2 }));
    clearDraft('invoice-new', 'u1');
    expect(store.has(KEY)).toBe(false);
    expect(store.has('jf:draft:u1:purchase-new')).toBe(true);
  });
});
