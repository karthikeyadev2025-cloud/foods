import { describe, expect, it } from 'vitest';
import { isDifferentUser } from './session';

/**
 * The bug this exists to stop: "when a user is in the process of creating a
 * bill and switches to another browser tab, the bill is reset when they
 * return."
 *
 * Supabase refreshes the access token on visibilitychange and raises an auth
 * event for it. The handler dropped the cached `me` query on EVERY auth event,
 * which put RequireAuth back to a full-screen spinner and unmounted every open
 * screen — with the half-typed bill inside it.
 */
describe('isDifferentUser', () => {
  // This is the case that was getting it wrong, and it is the whole fix.
  it('says no for the same user coming back to the tab', () => {
    expect(isDifferentUser('u1', 'u1')).toBe(false);
  });

  it('says yes when somebody else signs in', () => {
    expect(isDifferentUser('u1', 'u2')).toBe(true);
  });

  it('says yes on sign-out, so nothing of theirs is left behind', () => {
    expect(isDifferentUser('u1', null)).toBe(true);
    expect(isDifferentUser('u1', undefined)).toBe(true);
  });

  it('says yes on the first sign-in of the session', () => {
    expect(isDifferentUser(null, 'u1')).toBe(true);
  });

  // The very first auth event can arrive before getSession() has resolved, with
  // nobody signed in either side. Purging then would be harmless but pointless.
  it('says no when there was nobody and there still is nobody', () => {
    expect(isDifferentUser(null, null)).toBe(false);
    expect(isDifferentUser(undefined, null)).toBe(false);
  });
});
