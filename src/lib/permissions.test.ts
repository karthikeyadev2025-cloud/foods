import { describe, expect, it } from 'vitest';
import { FEATURES, featuresOutsidePlan, moduleFeature, planLabel } from './permissions';

describe('featuresOutsidePlan', () => {
  it('names what a Starter client loses when the trial ends', () => {
    const lost = featuresOutsidePlan('starter');
    expect(lost).toContain('Purchases');
    expect(lost).toContain('Quotations & pricing');
    expect(lost).toContain('Payments & accounts');
    expect(lost).toContain('Production');
    expect(lost).toContain('Vans & trips');
    // Not these — Starter keeps them, and a warning that says otherwise is a lie.
    expect(lost).not.toContain('Billing & collection');
    expect(lost).not.toContain('Attendance & wages');
  });

  it('leaves Growth only the Full features', () => {
    expect(featuresOutsidePlan('growth')).toEqual([
      'WhatsApp & calls',
      'Batches & barcodes',
      'Owner control',
      'Profit & incentives',
      'Driver’s phone',
      'Desktop & offline',
    ]);
  });

  it('takes nothing from Full, so the bar stays silent', () => {
    expect(featuresOutsidePlan('full')).toEqual([]);
  });

  it('accounts for every feature exactly once', () => {
    const kept = FEATURES.filter((f) => f.plan === 'starter').map((f) => f.label);
    expect(new Set([...kept, ...featuresOutsidePlan('starter')]).size).toBe(FEATURES.length);
  });
});

describe('moduleFeature', () => {
  it('keeps attendance separate, so Starter opens it while Payments stays shut', () => {
    expect(moduleFeature('attendance')).toBe('attendance');
    expect(moduleFeature('payments')).toBe('payments');
    expect(featuresOutsidePlan('starter')).not.toContain('Attendance & wages');
  });

  it('puts the counter work in core', () => {
    expect(moduleFeature('invoices')).toBe('core');
    expect(moduleFeature('customers')).toBe('core');
    expect(moduleFeature('stock')).toBe('core');
  });
});

describe('planLabel', () => {
  it('names the three plans', () => {
    expect(planLabel('starter')).toBe('Starter');
    expect(planLabel('growth')).toBe('Growth');
    expect(planLabel('full')).toBe('Full');
  });

  it('does not lock screens down before the licence has answered', () => {
    expect(planLabel(null)).toBe('Full');
    expect(planLabel(undefined)).toBe('Full');
  });
});
