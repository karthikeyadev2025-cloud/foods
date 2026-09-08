import { describe, expect, it } from 'vitest';
import { checkConnection } from './config';

/** The checks that run before the app ever touches the network. */
describe('checkConnection', () => {
  it('insists on an https project address', async () => {
    expect(await checkConnection({ url: 'abcdefgh.supabase.co', anonKey: 'x'.repeat(60) })).toMatch(/https:\/\//);
    expect(await checkConnection({ url: 'http://abcdefgh.supabase.co', anonKey: 'x'.repeat(60) })).toMatch(/https:\/\//);
  });

  it('catches a half-copied key', async () => {
    expect(await checkConnection({ url: 'https://abcdefgh.supabase.co', anonKey: 'eyJhbGciOi' })).toMatch(/too short/i);
  });

  it('refuses the service role key', async () => {
    const serviceKey = `eyJhbGciOiJIUzI1NiJ9.${'a'.repeat(40)}service_role${'b'.repeat(20)}`;
    expect(await checkConnection({ url: 'https://abcdefgh.supabase.co', anonKey: serviceKey })).toMatch(/service role/i);
  });
});
