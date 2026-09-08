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
});

describe('OfflineQueuedError', () => {
  it('carries the label for the toast', () => {
    const e = new OfflineQueuedError('Invoice for RAVI STORES');
    expect(e.label).toBe('Invoice for RAVI STORES');
    expect(e.name).toBe('OfflineQueuedError');
  });
});
