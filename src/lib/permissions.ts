import type { Database } from '@/types/supabase';

export type StaffRole = Database['public']['Enums']['staff_role'];

/**
 * Module keys. These are the values in `role_permissions.module` and the `module`
 * on each nav item, and what `can_view(module)` / `can_edit(module)` in RLS check.
 * Adding a module means a nav entry, a row per role in role_permissions, and
 * (if the data should be hidden, not just the screen) a policy in a migration.
 */
export const MODULES = [
  { key: 'dashboard', label: 'Dashboard' },
  { key: 'items', label: 'Items' },
  { key: 'customers', label: 'Customers' },
  { key: 'invoices', label: 'Sales invoices' },
  { key: 'purchases', label: 'Purchases' },
  { key: 'returns', label: 'Returns' },
  { key: 'receipts', label: 'Receipts' },
  { key: 'payments', label: 'Payments' },
  { key: 'stock', label: 'Stock' },
  { key: 'production', label: 'Production' },
  { key: 'vehicles', label: 'Vehicles' },
  { key: 'messaging', label: 'Messaging' },
  { key: 'reports', label: 'Reports' },
  { key: 'setup', label: 'Setup' },
] as const;

export type ModuleKey = (typeof MODULES)[number]['key'];

/**
 * Licence plans (db/21_plans.sql). The key the vendor issues carries one, and the plan
 * decides which features are unlocked. This mirrors `plan_features()` and
 * `feature_catalogue()` in the database — the database is what actually enforces it;
 * this copy only decides what to draw, and what to say when something is locked.
 */
export type PlanKey = 'starter' | 'growth' | 'full';
export const PLANS: { key: PlanKey; label: string; blurb: string }[] = [
  { key: 'starter', label: 'Starter', blurb: 'Billing and collection — the day-to-day counter work.' },
  { key: 'growth', label: 'Growth', blurb: 'The whole operation: buying, paying, returns, production, vans and documents.' },
  { key: 'full', label: 'Full', blurb: 'Everything, including WhatsApp and calls, batches, the owner tools and the driver’s phone.' },
];
export const planLabel = (p: PlanKey | null | undefined): string => PLANS.find((x) => x.key === p)?.label ?? 'Full';

export const FEATURES = [
  { key: 'core', label: 'Billing & collection', plan: 'starter', detail: 'Items, customers, invoices and prints, receipts, stock on hand, the day’s reports, setup and users' },
  { key: 'purchases', label: 'Purchases', plan: 'growth', detail: 'Supplier bills, suppliers, purchase returns' },
  { key: 'returns', label: 'Sales returns', plan: 'growth', detail: 'Fresh return, rate difference and damage return' },
  { key: 'payments', label: 'Payments & accounts', plan: 'growth', detail: 'Payments, expenses, cash and bank books, cheques, journal, trial balance, P&L, balance sheet' },
  { key: 'production', label: 'Production', plan: 'growth', detail: 'Recipes, batches, chief actuals, variance' },
  { key: 'vehicles', label: 'Vans & trips', plan: 'growth', detail: 'Trips, van loading, loading sheet, settlement' },
  { key: 'documents', label: 'Quotations & pricing', plan: 'growth', detail: 'Quotations, sale and purchase orders, delivery challans, price lists, discount schemes' },
  { key: 'messaging', label: 'WhatsApp & calls', plan: 'full', detail: 'Templates, payment reminders, broadcasts, inbound orders, reminder and order-taking calls' },
  { key: 'inventory', label: 'Batches & barcodes', plan: 'full', detail: 'Batch and expiry tracking, barcode labels, godown transfers, physical stock counts' },
  { key: 'owner', label: 'Owner control', plan: 'full', detail: 'Print designer, backup and restore, audit trail' },
  { key: 'insights', label: 'Profit & incentives', plan: 'full', detail: 'Route profitability and salesman incentive statements' },
  { key: 'mobile', label: 'Driver’s phone', plan: 'full', detail: 'Van sales, on-the-spot receipts and delivery proof from a phone' },
  { key: 'desktop', label: 'Desktop & offline', plan: 'full', detail: 'The installed Windows app, and working without a connection' },
] as const satisfies readonly { key: string; label: string; plan: PlanKey; detail: string }[];

export type FeatureKey = (typeof FEATURES)[number]['key'];
export const featureInfo = (f: FeatureKey) => FEATURES.find((x) => x.key === f);

/** Which feature a module belongs to — the eight Starter modules are all `core`. */
export function moduleFeature(m: ModuleKey): FeatureKey {
  switch (m) {
    case 'purchases':
    case 'returns':
    case 'payments':
    case 'production':
    case 'vehicles':
    case 'messaging':
      return m;
    default:
      return 'core';
  }
}

export const ROLES: { key: StaffRole; label: string; hint: string }[] = [
  { key: 'owner', label: 'Owner', hint: 'Everything, including rates, credit limits, licence and deletion' },
  { key: 'admin', label: 'Admin', hint: 'Everything except licence and org settings' },
  { key: 'accountant', label: 'Accountant', hint: 'Invoices, receipts, payments, returns, ledgers, reports. No item rates' },
  { key: 'store_keeper', label: 'Store keeper', hint: 'Items, purchases, van loading, stock adjustments, stock reports' },
  { key: 'production_head', label: 'Production head', hint: 'Recipes, batches, production sheet, raw material consumption' },
  { key: 'chief', label: 'Chief', hint: "Only today's open batch: actual usage and actual output" },
  { key: 'driver', label: 'Driver', hint: 'Own trip only: loaded list, deliveries, collections' },
  { key: 'sales_exec', label: 'Sales executive', hint: 'Customers, orders, invoices for own route, own collections' },
];

export function roleLabel(role: StaffRole | null | undefined): string {
  return ROLES.find((r) => r.key === role)?.label ?? String(role ?? '');
}
