import { describe, expect, it } from 'vitest';
import { isNetworkError, OfflineQueuedError } from './offline';

describe('isNetworkError', () => {
  it('recognises a dead connection', () => {
    expect(isNetworkError(new TypeError('Failed to fetch'))).toBe(true);
    expect(isNetworkError({ message: 'TypeError: NetworkError when attempting to fetch resource.' })).toBe(true);
    expect(isNetworkError(new Error('fetch failed'))).toBe(true);
  });
  it('leaves business errors alone', () => {
    expect(isNetworkError({ message: 'Licence key not recognised', code: 'P0001' })).toBe(false);
    expect(isNetworkError(new Error('Choose a customer'))).toBe(false);
  });

  /*
    The one from the shop. A purchase came back 500 and the screen said "Saved
    to the outbox — will be sent as soon as the connection is back". It never
    would have been: the connection was fine, the database had refused the call,
    and the reason was sitting unread in the response.

    postgrest-js gives a transport failure `code: ''` and everything the server
    answered the code it answered with, so the code is the whole test.
  */
  it('never files a database answer under "offline", whatever it says', () => {
    expect(isNetworkError({ message: 'canceling statement due to statement timeout', code: '57014' })).toBe(false);
    expect(isNetworkError({ message: 'canceling statement due to user request', code: '57014' })).toBe(false);
    expect(isNetworkError({ message: 'duplicate key value violates unique constraint', code: '23505' })).toBe(false);
    expect(isNetworkError({ message: 'Could not find the function public.save_purchase', code: 'PGRST202' })).toBe(false);
  });

  it('still recognises the transport failure, which carries no code', () => {
    expect(isNetworkError({ message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' })).toBe(true);
    expect(isNetworkError({ message: 'TypeError: Load failed', details: '', hint: '', code: '  ' })).toBe(true);
  });

  // Without a code there is nothing to go on but the wording, and a genuine
  // fetch timeout still has to reach the outbox.
  it('keeps treating an uncoded timeout as a lost connection', () => {
    expect(isNetworkError(new Error('The operation timed out'))).toBe(true);
  });
});

describe('OfflineQueuedError', () => {
  it('carries the label for the toast', () => {
    const e = new OfflineQueuedError('Invoice for RAVI STORES');
    expect(e.label).toBe('Invoice for RAVI STORES');
    expect(e.name).toBe('OfflineQueuedError');
  });
});
