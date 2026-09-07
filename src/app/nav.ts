import type { LucideIcon } from 'lucide-react';
import {
  BarChart3,
  Boxes,
  Factory,
  FileText,
  LayoutDashboard,
  MessageSquare,
  Package,
  Receipt,
  RotateCcw,
  Settings,
  ShoppingCart,
  Truck,
  Users,
  Wallet,
} from 'lucide-react';
import type { ModuleKey } from '@/lib/permissions';

/**
 * Sidebar navigation. `module` is the key used by `role_permissions.module`;
 * AppShell filters this list by the caller's role without touching the routes.
 */
export interface NavItem {
  to: string;
  label: string;
  icon: LucideIcon;
  module: ModuleKey;
}

export interface NavGroup {
  label: string;
  items: NavItem[];
}

export const NAV: NavGroup[] = [
  {
    label: 'Overview',
    items: [{ to: '/', label: 'Dashboard', icon: LayoutDashboard, module: 'dashboard' }],
  },
  {
    label: 'Masters',
    items: [
      { to: '/items', label: 'Items', icon: Package, module: 'items' },
      { to: '/customers', label: 'Customers', icon: Users, module: 'customers' },
    ],
  },
  {
    label: 'Transactions',
    items: [
      { to: '/invoices', label: 'Sales Invoices', icon: FileText, module: 'invoices' },
      { to: '/purchases', label: 'Purchases', icon: ShoppingCart, module: 'purchases' },
      { to: '/returns', label: 'Returns', icon: RotateCcw, module: 'returns' },
      { to: '/receipts', label: 'Receipts', icon: Receipt, module: 'receipts' },
      { to: '/payments', label: 'Payments', icon: Wallet, module: 'payments' },
    ],
  },
  {
    label: 'Operations',
    items: [
      { to: '/stock', label: 'Stock', icon: Boxes, module: 'stock' },
      { to: '/production', label: 'Production', icon: Factory, module: 'production' },
      { to: '/vehicles', label: 'Vehicles', icon: Truck, module: 'vehicles' },
      { to: '/messaging', label: 'Messaging', icon: MessageSquare, module: 'messaging' },
    ],
  },
  {
    label: 'Reports & Setup',
    items: [
      { to: '/reports', label: 'Reports', icon: BarChart3, module: 'reports' },
      { to: '/setup', label: 'Setup', icon: Settings, module: 'setup' },
    ],
  },
];
