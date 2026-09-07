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
