import { deviceInfo } from '@/lib/desktop';
import { expectRows, supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

/** From license_status() in db/18_licensing.sql. */
export interface LicenseStatus {
  status: 'trial' | 'unlicensed' | 'active' | 'grace' | 'expired';
  valid_till: string | null;
  days_left: number;
  read_only: boolean;
  grace_days: number;
  trial_days: number;
  licensed_to: string | null;
  has_key: boolean;
  devices: number;
  max_devices: number;
  this_device_known: boolean;
  checked_at: string;
}

export type LicenseDevice = Database['public']['Views']['v_license_devices']['Row'];

export async function getLicenseStatus(): Promise<LicenseStatus> {
  const d = await deviceInfo();
  const { data, error } = await supabase.rpc('license_status', { p_device_id: d.deviceId, p_app_version: d.version });
  if (error) throw error;
  return data as unknown as LicenseStatus;
}

export async function activateLicense(key: string): Promise<LicenseStatus> {
  const d = await deviceInfo();
  const { data, error } = await supabase.rpc('activate_license', {
    p_key: key,
    p_device_id: d.deviceId,
    p_device_name: d.deviceName,
    p_platform: d.platform,
    p_app_version: d.version,
  });
  if (error) throw error;
  return data as unknown as LicenseStatus;
}

export function listLicenseDevices(): Promise<LicenseDevice[]> {
  return expectRows(supabase.from('v_license_devices').select('*').order('activated_at'));
}

export async function removeLicenseDevice(id: string): Promise<void> {
  const { error } = await supabase.rpc('remove_license_device', { p_id: id });
  if (error) throw error;
}

export const LICENSE_LABEL: Record<LicenseStatus['status'], string> = {
  trial: 'Trial',
  unlicensed: 'Trial over',
  active: 'Licensed',
  grace: 'Renewal due',
  expired: 'Expired',
};
