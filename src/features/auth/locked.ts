import { moduleFeature, type FeatureKey, type ModuleKey } from '@/lib/permissions';

/**
 * Why a screen is not usable — and they are not the same thing.
 *
 * A module the ROLE may not see stays out of sight: a cashier has no business
 * knowing what is on the Payments screen, and showing it to them locked would
 * be an invitation, not information.
 *
 * A module the LICENCE PLAN withholds is shown, locked. The shop is being
 * asked to pay for it, so it has to be able to see what it is not getting. A
 * feature that is simply absent teaches nobody anything, and a client who
 * cannot see what he is missing has no reason to settle a bill.
 *
 * Both questions are asked of the same two facts, so they live together here
 * and are tested rather than reasoned about in a component.
 */
export type NotUsable = 'role' | 'plan' | null;

export function whyNotUsable(
  module: ModuleKey,
  opts: { roleCanView: boolean; planFeatures: FeatureKey[] | null; feature?: FeatureKey },
): NotUsable {
  // The licence has not answered yet: assume open rather than flashing a
  // padlock over every screen on each page load. The database refuses a
  // capped feature either way (db/21).
  const needed = opts.feature ?? moduleFeature(module);
  const lockedByPlan = opts.planFeatures !== null && !opts.planFeatures.includes(needed);

  // The role is asked first. A screen this person may not see is not advertised
  // to them just because the shop has not paid for it either.
  if (!opts.roleCanView) return 'role';
  return lockedByPlan ? 'plan' : null;
}

/** Shown in the menu and on the dashboard at all? Role-blocked things are not. */
export function isVisible(why: NotUsable): boolean {
  return why !== 'role';
}

/** Drawn blurred, with a padlock, and opening the "what this costs" screen. */
export function isLocked(why: NotUsable): boolean {
  return why === 'plan';
}
