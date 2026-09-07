import { expectOne, expectRows, supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Fns = Database['public']['Functions'];
export type TripRow = Database['public']['Views']['v_trip_list']['Row'];
export type TripStatus = Database['public']['Enums']['trip_status'];
export type SettlementRow = Fns['trip_settlement']['Returns'][number];
export type LoadingSheetRow = Fns['trip_loading_sheet']['Returns'][number];

export const TRIP_STATUSES: { value: TripStatus; label: string }[] = [
  { value: 'planned', label: 'Planned' },
  { value: 'loaded', label: 'Loaded' },
  { value: 'dispatched', label: 'On the road' },
  { value: 'settled', label: 'Settled' },
  { value: 'cancelled', label: 'Cancelled' },
];

/** Badge tone per status, shared by the list and the detail page. */
export const tripTone: Record<TripStatus, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  planned: 'outline',
  loaded: 'secondary',
  dispatched: 'default',
  settled: 'secondary',
  cancelled: 'destructive',
};

export function listTrips(opts: { status?: TripStatus | ''; from?: string; to?: string } = {}): Promise<TripRow[]> {
  let query = supabase.from('v_trip_list').select('*');
  if (opts.status) query = query.eq('status', opts.status);
  if (opts.from) query = query.gte('trip_date', opts.from);
  if (opts.to) query = query.lte('trip_date', opts.to);
  return expectRows(query.order('trip_date', { ascending: false }).order('created_at', { ascending: false }).limit(200));
}

export function listOpenTrips(): Promise<TripRow[]> {
  return expectRows(supabase.from('v_open_trips').select('*').order('trip_date', { ascending: false }));
}

export function getTrip(id: string): Promise<TripRow> {
  return expectOne(supabase.from('v_trip_list').select('*').eq('id', id).single());
}

export async function createTrip(input: { vehicle_id: string; route_id?: string | null; driver_id?: string | null; trip_date: string; opening_km?: number | null; notes?: string | null }): Promise<string> {
  const { data, error } = await supabase.rpc('create_trip', { p: { ...input } });
  if (error) throw error;
  return data;
}

export interface LoadLine {
  item_id: string;
  boxes: number;
}

export async function vanLoad(tripId: string, fromLocationId: string, lines: LoadLine[]): Promise<void> {
  const { error } = await supabase.rpc('van_load', { p_trip: tripId, p_from_location: fromLocationId, p_lines: lines.map((l) => ({ ...l })) });
  if (error) throw error;
}

export async function setTripStatus(tripId: string, status: TripStatus): Promise<void> {
  const { error } = await supabase.rpc('set_trip_status', { p_trip: tripId, p_status: status });
  if (error) throw error;
}

export async function settleTrip(tripId: string, toLocationId: string, closingKm: number | null, expenses: number | null, notes: string | null): Promise<void> {
  const { error } = await supabase.rpc('settle_trip', {
    p_trip: tripId,
    p_to_location: toLocationId,
    p_closing_km: closingKm ?? undefined,
    p_expenses: expenses ?? undefined,
    p_notes: notes ?? undefined,
  });
  if (error) throw error;
}

export async function tripSettlement(tripId: string): Promise<SettlementRow[]> {
  const { data, error } = await supabase.rpc('trip_settlement', { p_trip: tripId });
  if (error) throw error;
  return data ?? [];
}

export async function tripLoadingSheet(tripId: string): Promise<LoadingSheetRow[]> {
  const { data, error } = await supabase.rpc('trip_loading_sheet', { p_trip: tripId });
  if (error) throw error;
  return data ?? [];
}
