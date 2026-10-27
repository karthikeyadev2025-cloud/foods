import { describe, expect, it } from 'vitest';
import { isLocked, isVisible, whyNotUsable } from './locked';
import type { FeatureKey } from '@/lib/permissions';

// What the database hands back for each plan (db/21 plan_features).
const STARTER: FeatureKey[] = ['core', 'attendance'];
const GROWTH: FeatureKey[] = ['core', 'attendance', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents'];
const FULL: FeatureKey[] = [...GROWTH, 'messaging', 'inventory', 'owner', 'insights', 'mobile', 'desktop'];

describe('why a screen is not usable', () => {
  it('lets everything through on Full', () => {
    expect(whyNotUsable('purchases', { roleCanView: true, planFeatures: FULL })).toBeNull();
    expect(whyNotUsable('messaging', { roleCanView: true, planFeatures: FULL })).toBeNull();
  });

  it('calls a capped module a plan lock, not a role problem', () => {
    // The shop is on Growth: no WhatsApp.
    expect(whyNotUsable('messaging', { roleCanView: true, planFeatures: GROWTH })).toBe('plan');
    // On Starter the whole buying and paying side goes too.
    for (const m of ['purchases', 'returns', 'payments', 'production', 'vehicles'] as const) {
      expect(whyNotUsable(m, { roleCanView: true, planFeatures: STARTER })).toBe('plan');
    }
  });

  it('keeps billing and attendance open on Starter — that is what was paid for', () => {
    expect(whyNotUsable('invoices', { roleCanView: true, planFeatures: STARTER })).toBeNull();
    expect(whyNotUsable('customers', { roleCanView: true, planFeatures: STARTER })).toBeNull();
    expect(whyNotUsable('attendance', { roleCanView: true, planFeatures: STARTER })).toBeNull();
  });

  /*
    The one that matters. A cashier may not see Payments; the shop has also not
    paid for it. Showing that cashier a padlocked Payments tile would be
    advertising a screen they are not allowed to open — the role has to win.
  */
  it('hides a role-blocked screen even when the plan also withholds it', () => {
    const why = whyNotUsable('payments', { roleCanView: false, planFeatures: STARTER });
    expect(why).toBe('role');
    expect(isVisible(why)).toBe(false);
    expect(isLocked(why)).toBe(false);
  });

  it('hides a role-blocked screen the plan would have allowed', () => {
    expect(whyNotUsable('payments', { roleCanView: false, planFeatures: FULL })).toBe('role');
  });

  it('shows a plan-locked screen, blurred', () => {
    const why = whyNotUsable('production', { roleCanView: true, planFeatures: STARTER });
    expect(isVisible(why)).toBe(true);
    expect(isLocked(why)).toBe(true);
  });

  // A named feature beats the module's own: Stock is core, but batches and
  // barcodes inside it are Full-only.
  it('honours a feature named on the item', () => {
    expect(whyNotUsable('stock', { roleCanView: true, planFeatures: GROWTH })).toBeNull();
    expect(whyNotUsable('stock', { roleCanView: true, planFeatures: GROWTH, feature: 'inventory' })).toBe('plan');
  });

  // Until license_status answers, assume open: a padlock flashing onto every
  // screen on each page load would be worse than a moment of optimism, and the
  // database refuses a capped feature regardless.
  it('assumes open while the licence is still loading', () => {
    expect(whyNotUsable('messaging', { roleCanView: true, planFeatures: null })).toBeNull();
    expect(whyNotUsable('messaging', { roleCanView: false, planFeatures: null })).toBe('role');
  });
});
