import { createBrowserRouter } from 'react-router-dom';
import { AppShell } from '@/app/layout/AppShell';
import { NotFound } from '@/app/routes/NotFound';
import { Placeholder } from '@/app/routes/Placeholder';

/**
 * Route table. Each feature adds its own `routes/` and is mounted here by path.
 * Auth guarding arrives with T0.3; RLS is the real boundary either way.
 */
export const router = createBrowserRouter([
  {
    path: '/',
    element: <AppShell />,
    children: [
      { index: true, element: <Placeholder title="Dashboard" task="T5.1" /> },
      { path: 'items', element: <Placeholder title="Items" task="T1.2" /> },
      { path: 'customers', element: <Placeholder title="Customers" task="T1.3" /> },
      { path: 'invoices', element: <Placeholder title="Sales Invoices" task="T2.2" /> },
      { path: 'purchases', element: <Placeholder title="Purchases" task="T2.1" /> },
      { path: 'returns', element: <Placeholder title="Returns" task="T2.4" /> },
      { path: 'receipts', element: <Placeholder title="Receipts" task="T2.5" /> },
      { path: 'payments', element: <Placeholder title="Payments" task="T2.6" /> },
      { path: 'stock', element: <Placeholder title="Stock" task="T3.1" /> },
      { path: 'production', element: <Placeholder title="Production" task="T4.2" /> },
      { path: 'vehicles', element: <Placeholder title="Vehicles" task="T3.2" /> },
      { path: 'messaging', element: <Placeholder title="Messaging" task="T6.1" /> },
      { path: 'reports', element: <Placeholder title="Reports" task="T5.2" /> },
      { path: 'setup', element: <Placeholder title="Setup" task="T0.4" /> },
      { path: '*', element: <NotFound /> },
    ],
  },
]);
