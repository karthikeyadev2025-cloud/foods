import { createBrowserRouter, createHashRouter, type RouteObject } from 'react-router-dom';
import { AppShell } from '@/app/layout/AppShell';
import { MobileShell } from '@/app/layout/MobileShell';
import { MBillPage, MCollectPage, MStockPage, MStopPage, MStopsPage, MTripPage } from '@/features/mobile/routes/pages';
import { AccountsPage } from '@/features/accounts/routes/AccountsPage';
import { AttendancePage } from '@/features/attendance/routes/AttendancePage';
import { NotFound } from '@/app/routes/NotFound';
import { OutboxPage } from '@/app/routes/OutboxPage';
import { RequireAuth } from '@/features/auth/components/RequireAuth';
import { RequireModule } from '@/features/auth/components/RequireModule';
import { LoginPage } from '@/features/auth/routes/LoginPage';
import { WelcomePage } from '@/features/auth/routes/WelcomePage';
import { CustomersPage } from '@/features/customers/routes/CustomersPage';
import { DashboardPage } from '@/features/dashboard/routes/DashboardPage';
import { ChallanEditPage, ChallanPrintPage, ChallansPage } from '@/features/documents/routes/ChallansPage';
import { OrderEditPage, OrdersPage } from '@/features/documents/routes/OrdersPage';
import { PriceListsPage } from '@/features/documents/routes/PriceListsPage';
import { PurchaseReturnsPage } from '@/features/documents/routes/PurchaseReturnsPage';
import { QuotationEditPage, QuotationPrintPage, QuotationsPage } from '@/features/documents/routes/QuotationsPage';
import { InvoiceEditPage } from '@/features/invoices/routes/InvoiceEditPage';
import { InvoicePrintPage } from '@/features/invoices/routes/InvoicePrintPage';
import { InvoicesPage } from '@/features/invoices/routes/InvoicesPage';
import { ItemEditPage } from '@/features/items/routes/ItemEditPage';
import { CataloguePage } from '@/features/items/routes/CataloguePage';
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
import { LabelsPrintPage } from '@/features/stock/components/inventory';
import { CountSheetPage } from '@/features/stock/routes/CountSheetPage';
import { StockPage } from '@/features/stock/routes/StockPage';
import { TransferPrintPage } from '@/features/stock/routes/TransferPrintPage';
import { TripDetailPage } from '@/features/vehicles/routes/TripDetailPage';
import { TripPrintPage } from '@/features/vehicles/routes/TripPrintPage';
import { TripsPage } from '@/features/vehicles/routes/TripsPage';
import { VehiclesPage } from '@/features/vehicles/routes/VehiclesPage';
import { RequireFeature } from '@/features/auth/components/RequireFeature';
import { isDesktop } from '@/lib/desktop';
import type { FeatureKey, ModuleKey } from '@/lib/permissions';

/** Mount a feature's routes behind its module guard. */
function guarded(module: ModuleKey, children: RouteObject[]): RouteObject {
  return { element: <RequireModule module={module} />, children };
}

/** …and behind a licence plan feature, where the screen needs more than its module. */
function licensed(feature: FeatureKey, children: RouteObject[]): RouteObject {
  return { element: <RequireFeature feature={feature} />, children };
}

/**
 * Route table. `/login` is the only public route. Everything else sits behind
 * RequireAuth (session + org) and, per feature, RequireModule (role permission).
 * RLS is the real boundary; these guards decide what to draw.
 * The desktop shell loads dist/index.html from disk, so it routes by hash.
 */
const createRouter = isDesktop() ? createHashRouter : createBrowserRouter;
export const router = createRouter([
  { path: '/login', element: <LoginPage /> },
  {
    element: <RequireAuth />,
    children: [
      { path: '/welcome', element: <WelcomePage /> },
      // Print sheets render without the app chrome.
      guarded('invoices', [
        { path: '/invoices/:id/print', element: <InvoicePrintPage /> },
        { path: '/quotations/:id/print', element: <QuotationPrintPage /> },
        { path: '/challans/:id/print', element: <ChallanPrintPage /> },
      ]),
      guarded('vehicles', [{ path: '/vehicles/trips/:id/print', element: <TripPrintPage /> }]),
      guarded('stock', [
        licensed('inventory', [
          { path: '/stock/transfers/:id/print', element: <TransferPrintPage /> },
          { path: '/stock/labels', element: <LabelsPrintPage /> },
        ]),
      ]),
      // The phone: the driver's trip, stops, van sales, receipts and delivery proof.
      {
        path: '/m',
        element: <MobileShell />,
        children: [
          licensed('mobile', [
            { index: true, element: <MTripPage /> },
            { path: 'stops', element: <MStopsPage /> },
            { path: 'stops/:customerId', element: <MStopPage /> },
            { path: 'stops/:customerId/bill', element: <MBillPage /> },
            { path: 'stops/:customerId/collect', element: <MCollectPage /> },
            { path: 'stock', element: <MStockPage /> },
          ]),
          { path: 'outbox', element: <OutboxPage /> },
        ],
      },
      {
        path: '/',
        element: <AppShell />,
        children: [
          { index: true, element: <DashboardPage /> },
          guarded('items', [
            { path: 'items', element: <ItemsPage /> },
            { path: 'items/new', element: <ItemEditPage /> },
            { path: 'items/:id', element: <ItemEditPage /> },
            { path: 'catalogue', element: <CataloguePage /> },
          ]),
          guarded('customers', [{ path: 'customers', element: <CustomersPage /> }]),
          guarded('invoices', [
            { path: 'invoices', element: <InvoicesPage /> },
            { path: 'invoices/new', element: <InvoiceEditPage /> },
            { path: 'invoices/:id', element: <InvoiceEditPage /> },
            licensed('documents', [
              { path: 'quotations', element: <QuotationsPage /> },
              { path: 'quotations/new', element: <QuotationEditPage /> },
              { path: 'quotations/:id', element: <QuotationEditPage /> },
              { path: 'orders', element: <OrdersPage /> },
              { path: 'orders/purchase', element: <OrdersPage kind="purchase" /> },
              { path: 'orders/new', element: <OrderEditPage /> },
              { path: 'orders/:id', element: <OrderEditPage /> },
              { path: 'challans', element: <ChallansPage /> },
              { path: 'challans/new', element: <ChallanEditPage /> },
              { path: 'challans/:id', element: <ChallanEditPage /> },
            ]),
          ]),
          guarded('items', [
            licensed('documents', [
              { path: 'pricing', element: <PriceListsPage /> },
              { path: 'pricing/:tab', element: <PriceListsPage /> },
            ]),
          ]),
          guarded('purchases', [
            { path: 'purchases', element: <PurchasesPage /> },
            { path: 'purchases/suppliers', element: <PurchasesPage tab="suppliers" /> },
            { path: 'purchases/returns', element: <PurchaseReturnsPage /> },
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
          guarded('payments', [
            { path: 'payments', element: <PaymentsPage /> },
            { path: 'accounts', element: <AccountsPage /> },
            { path: 'accounts/:tab', element: <AccountsPage /> },
          ]),
          guarded('attendance', [
            { path: 'attendance', element: <AttendancePage /> },
            { path: 'attendance/wages', element: <AttendancePage tab="wages" /> },
          ]),
          guarded('stock', [
            { path: 'stock', element: <StockPage /> },
            { path: 'stock/movements', element: <StockPage tab="movements" /> },
            { path: 'stock/low', element: <StockPage tab="low" /> },
            { path: 'stock/batches', element: <StockPage tab="batches" /> },
            { path: 'stock/transfers', element: <StockPage tab="transfers" /> },
            { path: 'stock/counts', element: <StockPage tab="counts" /> },
            { path: 'stock/counts/:id', element: <CountSheetPage /> },
            { path: 'stock/barcodes', element: <StockPage tab="barcodes" /> },
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
            { path: 'reports/profit', element: <ReportsPage tab="profit" /> },
            { path: 'reports/incentives', element: <ReportsPage tab="incentives" /> },
          ]),
          guarded('setup', [
            { path: 'setup', element: <SetupPage /> },
            { path: 'setup/wizard', element: <SetupWizard /> },
            { path: 'setup/wizard/:step', element: <SetupWizard /> },
            { path: 'setup/:tab', element: <SetupPage /> },
          ]),
          { path: 'outbox', element: <OutboxPage /> },
          { path: '*', element: <NotFound /> },
        ],
      },
    ],
  },
]);
