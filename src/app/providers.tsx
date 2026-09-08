import { createAsyncStoragePersister } from '@tanstack/query-async-storage-persister';
import { QueryClient } from '@tanstack/react-query';
import { PersistQueryClientProvider } from '@tanstack/react-query-persist-client';
import { createStore, del, get, set } from 'idb-keyval';
import { useEffect, useState, type ReactNode } from 'react';
import { Toaster } from '@/components/ui/toaster';
import { AuthProvider } from '@/features/auth/components/AuthProvider';
import { toastError } from '@/hooks/use-toast';
import { APP_VERSION } from '@/lib/desktop';
import { loadOutbox, subscribeOnline } from '@/lib/offline';
import { replayOutbox } from '@/lib/supabase';

const DAY = 24 * 60 * 60 * 1000;

/** Query cache on disk (IndexedDB) so every screen already seen still opens offline. */
const cacheStore = typeof indexedDB === 'undefined' ? null : createStore('erp-cache', 'queries');
const persister = createAsyncStoragePersister({
  key: 'erp-query-cache',
  throttleTime: 2000,
  storage: cacheStore
    ? {
        getItem: (k) => get<string>(k, cacheStore).then((v) => v ?? null),
        setItem: (k, v) => set(k, v, cacheStore),
        removeItem: (k) => del(k, cacheStore),
      }
    : null,
});

/**
 * App-wide providers. TanStack Query is the only server-state layer (no Redux, no
 * Zustand for server data). Every mutation failure surfaces as a toast by default.
 * The cache is persisted for offline reads; queued writes replay when back online.
 */
export function Providers({ children }: { children: ReactNode }) {
  const [client] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 30_000,
            gcTime: DAY,
            retry: 1,
            refetchOnWindowFocus: false,
          },
          mutations: {
            onError: (err) => {
              toastError(err);
            },
          },
        },
      }),
  );

  useEffect(() => {
    void loadOutbox();
    const sync = () => {
      if (navigator.onLine)
        void replayOutbox().then((r) => {
          if (r.sent) void client.invalidateQueries();
        });
    };
    sync();
    return subscribeOnline(sync);
  }, [client]);

  return (
    <PersistQueryClientProvider
      client={client}
      persistOptions={{
        persister,
        maxAge: DAY,
        buster: APP_VERSION,
        dehydrateOptions: { shouldDehydrateQuery: (q) => q.state.status === 'success' },
      }}
    >
      <AuthProvider>{children}</AuthProvider>
      <Toaster />
    </PersistQueryClientProvider>
  );
}
