import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { useMe } from '@/features/auth/hooks';
import { listOpenTrips, type TripRow } from '@/features/vehicles/trips-api';
import { myOpenTrip, rememberedTrip, rememberTrip } from './api';

/**
 * The trip the phone works on: the driver's own open trip, else the one picked from
 * the open list (remembered on the device), else the only open trip if there is one.
 */
export function useActiveTrip() {
  const me = useMe();
  const isDriver = me.data?.role === 'driver';
  const [picked, setPicked] = useState<string | null>(() => rememberedTrip());
  const mine = useQuery({ queryKey: ['mobile', 'my_trip', me.data?.staff_id], queryFn: myOpenTrip, enabled: Boolean(me.data), staleTime: 60_000 });
  const open = useQuery({ queryKey: ['trips', 'open'], queryFn: listOpenTrips, enabled: Boolean(me.data), staleTime: 60_000 });
  const openList = open.data ?? [];
  const trip: TripRow | null = mine.data ?? openList.find((t) => t.id === picked) ?? (openList.length === 1 ? (openList[0] ?? null) : null);
  return {
    trip,
    isDriver,
    openTrips: openList,
    loading: mine.isLoading || open.isLoading,
    error: mine.error ?? open.error,
    pick: (id: string | null) => {
      rememberTrip(id);
      setPicked(id);
    },
  };
}
