import { currentOrgId } from '@/features/auth/api';
import type { TripRow } from '@/features/vehicles/trips-api';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Fns = Database['public']['Functions'];
export type StopRow = Fns['trip_stops']['Returns'][number];

/** The signed-in driver's trip for today (loaded or on the road), if any. */
export async function myOpenTrip(): Promise<TripRow | null> {
  const { data, error } = await supabase.rpc('my_open_trip');
  if (error) throw error;
  return (data?.[0] as TripRow | undefined) ?? null;
}

/** Every customer on the trip's route, with today's bills, deliveries and collections on the trip. */
export async function tripStops(tripId: string): Promise<StopRow[]> {
  const { data, error } = await supabase.rpc('trip_stops', { p_trip: tripId });
  if (error) throw error;
  return data ?? [];
}

/** Photo into the private `proofs` bucket; returns the storage path kept on the invoice. */
export async function uploadProof(invoiceId: string, file: File): Promise<string> {
  const org = await currentOrgId();
  const ext = file.type === 'image/png' ? 'png' : file.type === 'image/webp' ? 'webp' : 'jpg';
  const path = `${org}/${invoiceId}-${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from('proofs').upload(path, file, { contentType: file.type || 'image/jpeg', upsert: false });
  if (error) throw error;
  return path;
}

export async function proofUrl(path: string): Promise<string> {
  const { data, error } = await supabase.storage.from('proofs').createSignedUrl(path, 600);
  if (error) throw error;
  return data.signedUrl;
}

export async function markDelivered(invoiceId: string, opts: { photo?: string | null; receiver?: string | null; note?: string | null }): Promise<void> {
  const { error } = await supabase.rpc('mark_delivered', {
    p_invoice: invoiceId,
    ...(opts.photo ? { p_photo: opts.photo } : {}),
    ...(opts.receiver ? { p_receiver: opts.receiver } : {}),
    ...(opts.note ? { p_note: opts.note } : {}),
  });
  if (error) throw error;
}

/** Invoices on a trip for one customer, newest first (for the stop screen). */
export type TripInvoice = Database['public']['Views']['v_invoice_list']['Row'];
export async function tripInvoicesFor(tripId: string, customerId: string): Promise<TripInvoice[]> {
  const { data, error } = await supabase.from('v_invoice_list').select('*').eq('trip_id', tripId).eq('customer_id', customerId).neq('status', 'cancelled').order('created_at', { ascending: false });
  if (error) throw error;
  return data ?? [];
}

const TRIP_KEY = 'erp.m.trip';
export function rememberedTrip(): string | null {
  try {
    return localStorage.getItem(TRIP_KEY);
  } catch {
    return null;
  }
}
export function rememberTrip(id: string | null): void {
  try {
    if (id) localStorage.setItem(TRIP_KEY, id);
    else localStorage.removeItem(TRIP_KEY);
  } catch {
    // storage blocked: the pick lasts for the session only
  }
}
