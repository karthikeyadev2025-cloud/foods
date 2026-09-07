import { createBrowserRouter, type RouteObject } from 'react-router-dom';
import { AppShell } from '@/app/layout/AppShell';
import { NotFound } from '@/app/routes/NotFound';
import { Placeholder } from '@/app/routes/Placeholder';
import { RequireAuth } from '@/features/auth/components/RequireAuth';
import { RequireModule } from '@/features/auth/components/RequireModule';
import { LoginPage } from '@/features/auth/routes/LoginPage';
import { WelcomePage } from '@/features/auth/routes/WelcomePage';
import { SetupPage } from '@/features/setup/routes/SetupPage';
import { SetupWizard } from '@/features/setup/routes/SetupWizard';
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
      {
        path: '/',
        element: <AppShell />,
        children: [
          { index: true, element: <Placeholder title="Dashboard" task="T5.1" /> },
          guarded('items', [{ path: 'items', element: <Placeholder title="Items" task="T1.2" /> }]),
          guarded('customers', [{ path: 'customers', element: <Placeholder title="Customers" task="T1.3" /> }]),
          guarded('invoices', [{ path: 'invoices', element: <Placeholder title="Sales Invoices" task="T2.2" /> }]),
          guarded('purchases', [{ path: 'purchases', element: <Placeholder title="Purchases" task="T2.1" /> }]),
          guarded('returns', [{ path: 'returns', element: <Placeholder title="Returns" task="T2.4" /> }]),
          guarded('receipts', [{ path: 'receipts', element: <Placeholder title="Receipts" task="T2.5" /> }]),
          guarded('payments', [{ path: 'payments', element: <Placeholder title="Payments" task="T2.6" /> }]),
          guarded('stock', [{ path: 'stock', element: <Placeholder title="Stock" task="T3.1" /> }]),
          guarded('production', [{ path: 'production', element: <Placeholder title="Production" task="T4.2" /> }]),
          guarded('vehicles', [{ path: 'vehicles', element: <Placeholder title="Vehicles" task="T3.2" /> }]),
          guarded('messaging', [{ path: 'messaging', element: <Placeholder title="Messaging" task="T6.1" /> }]),
          guarded('reports', [{ path: 'reports', element: <Placeholder title="Reports" task="T5.2" /> }]),
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
