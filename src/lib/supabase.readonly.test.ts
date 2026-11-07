import { afterEach, describe, expect, it } from 'vitest';
import { setReadOnly } from './readonly';
import { supabase } from './supabase';

afterEach(() => setReadOnly(false));

/*
  The guard that matters, tested on the real client rather than a stub.

  The database refuses new DOCUMENTS when a licence lapses (db/18), and that is
  the boundary. But the masters — items, customers, suppliers, rates — are not
  document tables, so a frozen shop could have gone on adding products all day.
  Every write in the app goes through supabase.from(...), so that is where it
  is stopped.
*/
describe('a frozen app cannot write', () => {
  it('refuses a new master row', () => {
    setReadOnly(true);
    expect(() => supabase.from('items').insert({} as never)).toThrow(/read-only/i);
    expect(() => supabase.from('customers').insert({} as never)).toThrow(/read-only/i);
    expect(() => supabase.from('suppliers').insert({} as never)).toThrow(/read-only/i);
  });

  it('refuses an edit and a delete, not just an insert', () => {
    setReadOnly(true);
    expect(() => supabase.from('items').update({} as never)).toThrow(/read-only/i);
    expect(() => supabase.from('items').delete()).toThrow(/read-only/i);
    expect(() => supabase.from('items').upsert({} as never)).toThrow(/read-only/i);
  });

  // Reading has to keep working, or the shop cannot look up what a customer
  // owes, reprint yesterday's bill, or export anything for its accountant.
  it('still reads, and still builds a query', () => {
    setReadOnly(true);
    expect(() => supabase.from('items').select('*')).not.toThrow();
    expect(() => supabase.from('v_customer_list').select('*').eq('id', 'x')).not.toThrow();
  });

  it('writes again the moment the account is settled', () => {
    setReadOnly(true);
    expect(() => supabase.from('items').insert({} as never)).toThrow();
    setReadOnly(false);
    expect(() => supabase.from('items').insert({} as never)).not.toThrow();
  });
});
