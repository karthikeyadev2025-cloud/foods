import { describe, expect, it } from 'vitest';
import { errorCode, errorDetail, errorMessage } from './errors';

describe('errorMessage', () => {
  /**
   * The bug this file exists for. Deleting a product that is on a bill came back
   * from Supabase as a plain object, and the dialog rendered "[object Object]" —
   * so the one sentence that told the person what to do instead never appeared.
   */
  it('reads a Supabase failure, which is a plain object and not an Error', () => {
    const refusal = {
      code: '23503',
      details: null,
      hint: null,
      message: 'Item cannot be deleted: it is already on 3 stock movements. Set it inactive instead.',
    };
    expect(errorMessage(refusal)).toContain('Set it inactive instead');
    expect(errorMessage(refusal)).not.toContain('[object Object]');
    expect(errorCode(refusal)).toBe('23503');
  });

  it('reads a real Error too', () => {
    expect(errorMessage(new Error('Choose a customer'))).toBe('Choose a customer');
  });

  it('reads a bare string', () => {
    expect(errorMessage('Enter at least one amount')).toBe('Enter at least one amount');
  });

  it('never returns an empty message, whatever it is handed', () => {
    for (const odd of [null, undefined, {}, 0, [], new Error('')]) {
      expect(errorMessage(odd).length).toBeGreaterThan(0);
      expect(errorMessage(odd)).not.toContain('[object Object]');
    }
  });

  it('keeps the Postgres extras for the log without putting them on screen', () => {
    const e = { message: 'no', code: '23514', details: '3 bills reference it', hint: 'Try inactive' };
    expect(errorDetail(e)).toBe('3 bills reference it Try inactive');
    expect(errorMessage(e)).toBe('no');
  });
});
