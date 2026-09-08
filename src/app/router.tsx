import { createBrowserRouter, type RouteObject } from 'react-router-dom';
import { AppShell } from '@/app/layout/AppShell';
import { NotFound } from '@/app/routes/NotFound';
import { RequireAuth } from '@/features/auth/components/RequireAuth';
import { RequireModule } from '@/features/auth/components/RequireModule';
import { LoginPage } from '@/features/auth/routes/LoginPage';
import { WelcomePage } from '@/features/auth/routes/WelcomePage';
import { CustomersPage } from '@/features/customers/routes/CustomersPage';
import { DashboardPage } from '@/features/dashboard/routes/DashboardPage';
import { InvoiceEditPage } from '@/features/invoices/routes/InvoiceEditPage';
import { InvoicePrintPage } from '@/features/invoices/routes/InvoicePrintPage';
import { InvoicesPage } from '@/features/invoices/routes/InvoicesPage';
import { ItemEditPage } from '@/features/items/routes/ItemEditPage';
import { ItemsPage } from '@/features/items/routes/ItemsPage';
import { InboundOrderPage } from '@/features/messaging/routes/InboundOrderPage';
import { MessagingPage } from '@/features/messaging/routes/MessagingPage';
import { PaymentsPage } from '@/features/payments/routes/PaymentsPage';
import { BatchPage } from '@/features/production/routes/BatchPage';
import { ProductionPage } from '@/features/production/routes/ProductionPage';
import { PurchaseNewPage, PurchaseViewPage, PurchasesPage } from '@/features/purchases/routes/PurchasesPage';
import { ReceiptNewPage, ReceiptViewPage, ReceiptsPage } from '@/features/receipts/routes/ReceiptsPage';
import { ReportsPage } from '@/features/reports/routes/ReportsPage';
import { ReturnNewPage, ReturnViewPage, ReturnsPage } from '@/features/returns/routes/ReturnsPage';
import { SetupPage } from '@/features/setup/routes/SetupPage';
import { SetupWizard } from '@/features/setup/routes/SetupWizard';
import { StockPage } from '@/features/stock/routes/StockPage';
import { TripDetailPage } from '@/features/vehicles/routes/TripDetailPage';
import { TripPrintPage } from '@/features/vehicles/routes/TripPrintPage';
import { TripsPage } from '@/features/vehicles/routes/TripsPage';
import { VehiclesPage } from '@/features/vehicles/routes/VehiclesPage';
import type { ModuleKey } from '@/lib/permissions';

/** Mount a feature's routes behind its module guard. */
function guarded(module: ModuleKey, children: RouteObject[]): RouteObject {
  return { element: <RequireModule module={module} />, children };
}

/**
 * Route table. `/login` is the only public route. Everything else sits behind
 * RequireAuth (session + org) and, per feature, RequireModule (role permission).
 * RLS is the real boundary; these guards decide what to draw.
 */
export const router = createBrowserRouter([
  { path: '/login', element: <LoginPage /> },
  {
    element: <RequireAuth />,
    children: [
      { path: '/welcome', element: <WelcomePage /> },
      // Print sheets render without the app chrome.
      guarded('invoices', [{ path: '/invoices/:id/print', element: <InvoicePrintPage /> }]),
      guarded('vehicles', [{ path: '/vehicles/trips/:id/print', element: <TripPrintPage /> }]),
      {
        path: '/',
        element: <AppShell />,
        children: [
          { index: true, element: <DashboardPage /> },
          guarded('items', [
            { path: 'items', element: <ItemsPage /> },
            { path: 'items/new', element: <ItemEditPage /> },
            { path: 'items/:id', element: <ItemEditPage /> },
          ]),
          guarded('customers', [{ path: 'customers', element: <CustomersPage /> }]),
          guarded('invoices', [
            { path: 'invoices', element: <InvoicesPage /> },
            { path: 'invoices/new', element: <InvoiceEditPage /> },
            { path: 'invoices/:id', element: <InvoiceEditPage /> },
          ]),
          guarded('purchases', [
            { path: 'purchases', element: <PurchasesPage /> },
            { path: 'purchases/suppliers', element: <PurchasesPage tab="suppliers" /> },
            { path: 'purchases/new', element: <PurchaseNewPage /> },
            { path: 'purchases/:id', element: <PurchaseViewPage /> },
          ]),
          guarded('returns', [
            { path: 'returns', element: <ReturnsPage /> },
            { path: 'returns/new', element: <ReturnNewPage /> },
            { path: 'returns/:id', element: <ReturnViewPage /> },
          ]),
          guarded('receipts', [
            { path: 'receipts', element: <ReceiptsPage /> },
            { path: 'receipts/new', element: <ReceiptNewPage /> },
            { path: 'receipts/:id', element: <ReceiptViewPage /> },
          ]),
          guarded('payments', [{ path: 'payments', element: <PaymentsPage /> }]),
          guarded('stock', [
            { path: 'stock', element: <StockPage /> },
            { path: 'stock/movements', element: <StockPage tab="movements" /> },
            { path: 'stock/low', element: <StockPage tab="low" /> },
          ]),
          guarded('production', [
            { path: 'production', element: <ProductionPage /> },
            { path: 'production/recipes', element: <ProductionPage tab="recipes" /> },
            { path: 'production/variance', element: <ProductionPage tab="variance" /> },
            { path: 'production/batches/:id', element: <BatchPage /> },
          ]),
          guarded('vehicles', [
            { path: 'vehicles', element: <VehiclesPage /> },
            { path: 'vehicles/trips', element: <TripsPage /> },
            { path: 'vehicles/trips/:id', element: <TripDetailPage /> },
          ]),
          guarded('messaging', [
            { path: 'messaging', element: <MessagingPage /> },
            { path: 'messaging/orders/:id', element: <InboundOrderPage /> },
            { path: 'messaging/:tab', element: <MessagingPage /> },
          ]),
          guarded('reports', [
            { path: 'reports', element: <ReportsPage /> },
            { path: 'reports/ledger', element: <ReportsPage tab="ledger" /> },
            { path: 'reports/ageing', element: <ReportsPage tab="ageing" /> },
            { path: 'reports/modes', element: <ReportsPage tab="modes" /> },
            { path: 'reports/routes', element: <ReportsPage tab="routes" /> },
            { path: 'reports/sales', element: <ReportsPage tab="sales" /> },
          ]),
          guarded('setup', [
            { path: 'setup', element: <SetupPage /> },
            { path: 'setup/wizard', element: <SetupWizard /> },
            { path: 'setup/wizard/:step', element: <SetupWizard /> },
            { path: 'setup/:tab', element: <SetupPage /> },
          ]),
          { path: '*', element: <NotFound /> },
        ],
      },
    ],
  },
]);
