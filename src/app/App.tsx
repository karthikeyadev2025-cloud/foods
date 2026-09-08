import { RouterProvider } from 'react-router-dom';
import { Providers } from '@/app/providers';
import { router } from '@/app/router';
import { ConnectPage } from '@/features/auth/routes/ConnectPage';
import { isSupabaseConfigured } from '@/lib/supabase';

export function App() {
  // Nothing can load without a project to load it from, so ask before anything else runs.
  if (!isSupabaseConfigured) return <ConnectPage />;
  return (
    <Providers>
      <RouterProvider router={router} />
    </Providers>
  );
}
