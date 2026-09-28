import { describe, expect, it, vi } from 'vitest';
import type { PostgrestError } from '@supabase/supabase-js';
import { expectRowsOrUnordered } from './supabase';

const pgError = (code: string, message: string): PostgrestError =>
  ({ code, message, details: '', hint: '', name: 'PostgrestError' }) as PostgrestError;

/**
 * The SQL is applied by hand in the Supabase editor; the front end deploys the
 * moment a commit lands. So the app is routinely ahead of the schema for an
 * afternoon, and db/55 proved what that costs: every purchase view, edit and
 * print answered 400 because line_no was not there yet.
 */
describe('expectRowsOrUnordered', () => {
  it('uses the new ordering when the column is there', async () => {
    const run = vi.fn(async () => ({ data: [{ id: 'a' }], error: null }));
    await expect(expectRowsOrUnordered(run)).resolves.toEqual([{ id: 'a' }]);
    expect(run).toHaveBeenCalledTimes(1);
    expect(run).toHaveBeenCalledWith(true);
  });

  // The one that matters: the screen keeps working, in last week's order,
  // until somebody runs the migration.
  it('falls back to the old ordering when the column is not there yet', async () => {
    const run = vi.fn(async (byLineNo: boolean) =>
      byLineNo
        ? { data: null, error: pgError('42703', 'column v_purchase_lines.line_no does not exist') }
        : { data: [{ id: 'a' }, { id: 'b' }], error: null },
    );
    await expect(expectRowsOrUnordered(run)).resolves.toEqual([{ id: 'a' }, { id: 'b' }]);
    expect(run).toHaveBeenNthCalledWith(2, false);
  });

  // Recovering from anything else would hide a real fault behind a query that
  // quietly did something different.
  it('throws every other failure, and never retries it', async () => {
    const run = vi.fn(async () => ({ data: null, error: pgError('42501', 'permission denied') }));
    await expect(expectRowsOrUnordered(run)).rejects.toMatchObject({ code: '42501' });
    expect(run).toHaveBeenCalledTimes(1);
  });

  it('gives up if the fallback fails too, rather than returning nothing', async () => {
    const run = vi.fn(async (byLineNo: boolean) => ({
      data: null,
      error: byLineNo ? pgError('42703', 'no such column') : pgError('57014', 'statement timeout'),
    }));
    await expect(expectRowsOrUnordered(run)).rejects.toMatchObject({ code: '57014' });
  });

  it('reads an empty document as no lines, not as a failure', async () => {
    await expect(expectRowsOrUnordered(async () => ({ data: null, error: null }))).resolves.toEqual([]);
  });
});
