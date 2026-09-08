import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/supabase';

type Fns = Database['public']['Functions'];
type Enums = Database['public']['Enums'];

export type AttendStatus = Enums['attend_status'];
export type RegisterRow = Fns['attendance_register']['Returns'][number];
export type SummaryRow = Fns['attendance_summary']['Returns'][number];
export type RosterRow = Fns['punchly_roster']['Returns'][number];

export const STATUSES: { key: AttendStatus; label: string; tone: 'default' | 'secondary' | 'destructive' | 'outline' }[] = [
  { key: 'present', label: 'Present', tone: 'default' },
  { key: 'half_day', label: 'Half day', tone: 'secondary' },
  { key: 'absent', label: 'Absent', tone: 'destructive' },
  { key: 'leave', label: 'Leave', tone: 'outline' },
  { key: 'holiday', label: 'Holiday', tone: 'outline' },
];
export const statusLabel = (s: AttendStatus | null | undefined) => STATUSES.find((x) => x.key === s)?.label ?? String(s ?? '');
export const statusTone = (s: AttendStatus | null | undefined) => STATUSES.find((x) => x.key === s)?.tone ?? 'outline';

export async function attendanceRegister(from: string, to: string, staffId?: string | null): Promise<RegisterRow[]> {
  const { data, error } = await supabase.rpc('attendance_register', {
    p_from: from,
    p_to: to,
    ...(staffId ? { p_staff: staffId } : {}),
  });
  if (error) throw error;
  return data ?? [];
}

export async function attendanceSummary(from: string, to: string): Promise<SummaryRow[]> {
  const { data, error } = await supabase.rpc('attendance_summary', { p_from: from, p_to: to });
  if (error) throw error;
  return data ?? [];
}

export interface AttendanceInput {
  staff_id: string;
  work_date: string;
  status: AttendStatus;
  in_time?: string | null;
  out_time?: string | null;
  ot_hours?: number | null;
  wage_amount?: number | null;
  notes?: string | null;
}

/** Typing a day in marks the row `manual`, and no later Punchly sync overwrites it. */
export async function saveAttendance(v: AttendanceInput): Promise<string> {
  const { data, error } = await supabase.rpc('save_attendance', { p: { ...v } });
  if (error) throw error;
  return data;
}

// ---------------- Punchly ----------------
export interface PunchlySettings {
  is_enabled: boolean;
  api_url: string;
  has_api_key: boolean;
  api_key_hint: string | null;
  full_day_hours: number;
  half_day_hours: number;
  auto_wage: boolean;
  store_location: boolean;
  backfill_from: string | null;
  last_sync_at: string | null;
  last_sync_note: string | null;
}

/** The key itself never comes back — only whether there is one, and its last four. */
export async function getPunchlySettings(): Promise<PunchlySettings> {
  const { data, error } = await supabase.rpc('get_punchly_settings');
  if (error) throw error;
  return data as unknown as PunchlySettings;
}

export type PunchlyPatch = Partial<Omit<PunchlySettings, 'has_api_key' | 'api_key_hint' | 'last_sync_at' | 'last_sync_note'>> & {
  api_key?: string;
};

export async function savePunchlySettings(p: PunchlyPatch): Promise<PunchlySettings> {
  const { data, error } = await supabase.rpc('save_punchly_settings', { p: { ...p } });
  if (error) throw error;
  return data as unknown as PunchlySettings;
}

export async function punchlyRoster(): Promise<RosterRow[]> {
  const { data, error } = await supabase.rpc('punchly_roster');
  if (error) throw error;
  return data ?? [];
}

export async function linkPunchlyStaff(staffId: string, userId: string | null, staffCode?: string | null): Promise<void> {
  const { error } = await supabase.rpc('link_punchly_staff', {
    p_staff: staffId,
    p_user_id: userId ?? '',
    ...(staffCode ? { p_staff_code: staffCode } : {}),
  });
  if (error) throw error;
}

export interface SyncResult {
  org_id: string;
  written: number;
  kept_manual: number;
  skipped: number;
  days: string;
  backfill_left?: string | null;
  error?: string;
  staff?: { linked: number; matched_by_name: number; unmatched_count: number; unmatched: { user_id: string; staff_id: string; full_name: string }[] };
}

/** Fetch now rather than waiting for the half-hourly run. */
export async function syncPunchlyNow(): Promise<SyncResult[]> {
  const { data, error } = await supabase.functions.invoke<{ synced: SyncResult[]; note?: string } | { error: string }>('punchly-sync', { body: {} });
  if (error) throw error;
  if (!data || 'error' in data) throw new Error(data?.error ?? 'punchly-sync returned nothing');
  return data.synced;
}
