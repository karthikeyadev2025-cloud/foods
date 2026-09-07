import { currentOrgId } from '@/features/auth/api';
import { expectOne, expectRows, supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Tables = Database['public']['Tables'];
export type VehicleRow = Database['public']['Views']['v_vehicle_list']['Row'];
export type Vehicle = Tables['vehicles']['Row'];

export function listVehicles(): Promise<VehicleRow[]> {
  return expectRows(supabase.from('v_vehicle_list').select('*').order('vehicle_number'));
}

export type VehicleInsert = Omit<Tables['vehicles']['Insert'], 'org_id' | 'location_id'>;
export type VehicleUpdate = Omit<Tables['vehicles']['Update'], 'location_id'>;

/** The stock location is created by the DB trigger (db/08_masters.sql); never set here. */
export async function createVehicle(values: VehicleInsert): Promise<Vehicle> {
  return expectOne(supabase.from('vehicles').insert({ ...values, org_id: await currentOrgId() }).select('*').single());
}

export function updateVehicle(id: string, values: VehicleUpdate): Promise<Vehicle> {
  return expectOne(supabase.from('vehicles').update(values).eq('id', id).select('*').single());
}
