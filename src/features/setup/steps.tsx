import type { ComponentType } from 'react';
import { ImportPanel } from './components/ImportPanel';
import { OrgProfileForm } from './components/OrgProfileForm';
import { PermissionsMatrix } from './components/PermissionsMatrix';
import { UsersPanel } from './components/UsersPanel';
import {
  ExpenseHeadsPanel,
  NumberSeriesPanel,
  PackTypesPanel,
  ReceiptModesPanel,
  RoutesPanel,
  SectionsPanel,
  StockLocationsPanel,
  UomsPanel,
} from './components/panels';

export interface SetupStep {
  slug: string;
  label: string;
  /** One line shown in the wizard explaining why this step exists. */
  why: string;
  Component: ComponentType<{ compact?: boolean }>;
}

/**
 * The setup wizard's steps, in order — and the tabs of the Setup screen, since
 * every step is also a standalone screen afterwards (BUILD_TASKS T0.4).
 */
export const SETUP_STEPS: SetupStep[] = [
  {
    slug: 'org',
    label: 'Business',
    why: 'Trade name, address and the printed trade terms: breakage recovery %, interest %, credit days, jurisdiction.',
    Component: OrgProfileForm,
  },
  {
    slug: 'units',
    label: 'Units',
    why: 'Boxes, jars, packs, kilos. Every quantity in the system is a number plus one of these.',
    Component: UomsPanel,
  },
  {
    slug: 'pack-types',
    label: 'Pack types',
    why: 'The "Pack" label on the stock report and prints: JAR, PACK, L.B, KG, TRY.',
    Component: PackTypesPanel,
  },
  {
    slug: 'receipt-modes',
    label: 'Receipt modes',
    why: 'Cash, bank, UPI, cheque, BSR, BRK. Each active mode becomes a column on the receipts register.',
    Component: ReceiptModesPanel,
  },
  {
    slug: 'expense-heads',
    label: 'Expense heads',
    why: 'Categories for payments that are not to a supplier or staff.',
    Component: ExpenseHeadsPanel,
  },
  {
    slug: 'users',
    label: 'Users',
    why: 'Logins for staff, and who is a mestri. Add mestris here first so sections can be assigned to them.',
    Component: UsersPanel,
  },
  {
    slug: 'sections',
    label: 'Sections',
    why: 'The mestri sections the stock report groups by, in the order they print.',
    Component: SectionsPanel,
  },
  {
    slug: 'locations',
    label: 'Locations',
    why: 'Godowns and the production floor. Vehicles add their own location when created.',
    Component: StockLocationsPanel,
  },
  {
    slug: 'routes',
    label: 'Routes',
    why: 'The van lines customers and vehicles are assigned to.',
    Component: RoutesPanel,
  },
  {
    slug: 'numbering',
    label: 'Numbering',
    why: 'Prefix, digits, suffix and reset rule for each document type.',
    Component: NumberSeriesPanel,
  },
  {
    slug: 'permissions',
    label: 'Permissions',
    why: 'What each role can view, edit and delete. Enforced by the database.',
    Component: PermissionsMatrix,
  },
  {
    slug: 'import',
    label: 'Import data',
    why: 'Load sections, items, opening stock, customers and rates from Excel/CSV — or from the client’s own decoded files. Check first, then import; error rows come back to you.',
    Component: ImportPanel,
  },
];
