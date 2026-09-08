import { useEffect, useSyncExternalStore } from 'react';
import { isOnline, loadOutbox, outboxItems, outboxLoaded, subscribeOnline, subscribeOutbox } from '@/lib/offline';

/** True while the browser reports a connection. */
export function useOnline(): boolean {
  return useSyncExternalStore(subscribeOnline, isOnline, () => true);
}

/** The queued writes, kept fresh as items are added, sent or discarded. */
export function useOutbox() {
  const items = useSyncExternalStore(subscribeOutbox, outboxItems, outboxItems);
  useEffect(() => {
    if (!outboxLoaded()) void loadOutbox();
  }, []);
  return items;
}
