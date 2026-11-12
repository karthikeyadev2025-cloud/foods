import { currentOrgId } from '@/features/auth/api';
import { expectOk, expectRows, supabase } from '@/lib/supabase';
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
  /** How often Punchly is re-read wider, to catch a day an admin corrected afterwards. */
  reconcile_days: number;
  last_reconcile_at: string | null;
  backfill_from: string | null;
  last_sync_at: string | null;
  last_sync_note: string | null;
  // The payroll rules (db/73). They live on the same row because the wage
  // maths needs full_day_hours, which was already there.
  /** Are the overtime hours PAID? They are counted either way. */
  pay_ot: boolean;
  /** 1 = the same rate as ordinary hours, 1.5 = time and a half. */
  ot_multiplier: number;
  /** 0 = Sunday … 6 = Saturday; null = the shop works every day. */
  week_off_dow: number | null;
  paid_week_off: boolean;
  paid_holidays: boolean;
}

/** The key itself never comes back — only whether there is one, and its last four. */
export async function getPunchlySettings(): Promise<PunchlySettings> {
  const { data, error } = await supabase.rpc('get_punchly_settings');
  if (error) throw error;
  return data as unknown as PunchlySettings;
}

export type PunchlyPatch = Partial<
  Omit<PunchlySettings, 'has_api_key' | 'api_key_hint' | 'last_sync_at' | 'last_sync_note' | 'last_reconcile_at'>
> & { api_key?: string };

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

/**
 * An employee asks to be forgotten. Their days go, and so does the Punchly link — without
 * that the next sync would simply fetch them back. Owner only. Returns the days removed.
 */
export async function forgetStaffAttendance(staffId: string): Promise<number> {
  const { data, error } = await supabase.rpc('forget_staff_attendance', { p_staff: staffId });
  if (error) throw error;
  return data ?? 0;
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

// ------------------------------------------------------------
// Payroll (db/73)
// ------------------------------------------------------------
type Tbl = Database['public']['Tables'];
export type WageRow = Fns['wage_sheet']['Returns'][number];
export type WageRun = Fns['wage_runs']['Returns'][number];
export type LeaveBalanceRow = Fns['leave_balance']['Returns'][number];
export type Holiday = Tbl['holidays']['Row'];
export type LeaveType = Tbl['leave_types']['Row'];
export type StaffAdvance = Tbl['staff_advances']['Row'];

/**
 * The sheet somebody pays from: days, hours, overtime, what is still owed on
 * advances, and the net. Replaces attendanceSummary for the wages tab —
 * that one summed a full day or half a day and never a paisa of overtime.
 */
export async function wageSheet(from: string, to: string): Promise<WageRow[]> {
  const { data, error } = await supabase.rpc('wage_sheet', { p_from: from, p_to: to });
  if (error) throw error;
  return data ?? [];
}

export async function wageRuns(): Promise<WageRun[]> {
  const { data, error } = await supabase.rpc('wage_runs');
  if (error) throw error;
  return data ?? [];
}

export interface PayWagesResult {
  run_id: string;
  staff_count: number;
  basic: number;
  overtime: number;
  advance_recovered: number;
  net_paid: number;
}

/**
 * Pay a period. Needs the Payments right as well as Attendance, because
 * reading a wage sheet and emptying the till are two different jobs.
 */
export async function payWages(input: { period_from: string; period_to: string; paid_on?: string; mode_id: string; account_id?: string | null; notes?: string }): Promise<PayWagesResult> {
  const { data, error } = await supabase.rpc('pay_wages', { p: { ...input } as never });
  if (error) throw error;
  return data as unknown as PayWagesResult;
}

export async function saveStaffAdvance(input: { staff_id: string; amount: number; advance_date?: string; mode_id?: string | null; notes?: string }): Promise<string> {
  const { data, error } = await supabase.rpc('save_staff_advance', { p: { ...input } as never });
  if (error) throw error;
  return data as string;
}

export function listAdvances(): Promise<StaffAdvance[]> {
  return expectRows(supabase.from('staff_advances').select('*').order('advance_date', { ascending: false }));
}

export async function leaveBalance(staffId: string, year?: number): Promise<LeaveBalanceRow[]> {
  const { data, error } = await supabase.rpc('leave_balance', { p_staff: staffId, ...(year ? { p_year: year } : {}) });
  if (error) throw error;
  return data ?? [];
}

// The calendar and the leave kinds are ordinary tables behind the attendance
// module, so they are read and written directly.
export function listHolidays(): Promise<Holiday[]> {
  return expectRows(supabase.from('holidays').select('*').order('holiday_date'));
}

export async function saveHoliday(v: { id?: string; holiday_date: string; name: string; is_paid: boolean | null }): Promise<void> {
  const org_id = await currentOrgId();
  if (v.id) {
    await expectOk(supabase.from('holidays').update({ holiday_date: v.holiday_date, name: v.name, is_paid: v.is_paid }).eq('id', v.id));
    return;
  }
  await expectOk(supabase.from('holidays').insert({ org_id, holiday_date: v.holiday_date, name: v.name, is_paid: v.is_paid }));
}

export function deleteHoliday(id: string): Promise<void> {
  return expectOk(supabase.from('holidays').delete().eq('id', id));
}

export function listLeaveTypes(): Promise<LeaveType[]> {
  return expectRows(supabase.from('leave_types').select('*').order('code'));
}

export async function saveLeaveType(v: { id?: string; code: string; name: string; days_per_year: number; is_paid: boolean; is_active: boolean }): Promise<void> {
  const org_id = await currentOrgId();
  if (v.id) {
    const { id, ...rest } = v;
    await expectOk(supabase.from('leave_types').update(rest).eq('id', id));
    return;
  }
  await expectOk(supabase.from('leave_types').insert({ ...v, org_id }));
}
