// Punchly attendance client, shared by the edge functions.
//
// Punchly (https://punchly.online/api/v1) is the phone app the staff punch on. It is
// read-only and has no webhooks, so the ERP polls it:
//
//   GET /staff                          the roster — user_id, staff_id, full_name, …
//   GET /attendance?from&to&limit&offset the punches — one row per check_in / check_out
//
// The limits that shape this file:
//   • 1000 requests an hour per key, so pages are asked for at the maximum size
//   • limit is clamped to 1–1000 and a range may not span more than 366 days
//   • 429 comes with Retry-After, and it is meant to be obeyed
//   • attendance_date is already IST; occurred_at is UTC. The ERP groups on the former,
//     because grouping a night shift on its UTC timestamp lands it on the wrong day.

export interface PunchlyStaff {
  user_id: string;
  staff_id: string;
  full_name: string;
  designation?: string | null;
  branch_name?: string | null;
  is_active?: boolean;
  date_of_joining?: string | null;
}

export interface PunchlyPunch {
  record_id: string;
  staff_id: string;
  full_name: string;
  kind: 'check_in' | 'check_out';
  occurred_at: string;
  attendance_date: string;
  branch_name?: string | null;
  shift_name?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  enforcement_status?: string | null;
}

const PAGE = 1000;
/** Punchly rejects a span over 366 days. 365 leaves no room to argue about inclusivity. */
const MAX_SPAN_DAYS = 365;
/**
 * How much history one chunk asks for. Well under the 366-day cap, and deliberately so:
 * a whole window's punches are held in memory here before the fold, because a day's
 * check-in and check-out can land on different pages and folding half a day would write
 * a day with no check-in. Punchly reckons fifty staff make about 30,000 rows a year, so a
 * year in one window is several megabytes and five years for a larger client is far worse.
 * A quarter keeps that to a few thousand rows while costing about the same number of
 * requests — the row count drives the paging either way.
 */
const BACKFILL_WINDOW_DAYS = 91;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Punchly said no in a way worth repeating to the owner rather than swallowing. */
export class PunchlyError extends Error {
  constructor(message: string, readonly status: number, readonly code?: string) {
    super(message);
  }
}

export class PunchlyClient {
  constructor(private readonly baseUrl: string, private readonly apiKey: string) {}

  private async get(path: string, params: Record<string, string> = {}): Promise<Record<string, unknown>> {
    const url = new URL(this.baseUrl.replace(/\/+$/, '') + path);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);

    // Two extra tries, and only for the two failures that can pass on their own.
    for (let attempt = 0; ; attempt++) {
      const res = await fetch(url, {
        headers: { Authorization: `Bearer ${this.apiKey}`, Accept: 'application/json' },
      });
      if (res.ok) return await res.json();

      // Punchly's errors are JSON carrying a human `error` and a stable `code`. Branch on
      // the code, never on the message — the message is theirs to reword.
      const raw = await res.text();
      let code: string | undefined;
      let message = raw.slice(0, 300);
      try {
        const body = JSON.parse(raw) as { error?: string; code?: string };
        code = body.code;
        if (body.error) message = body.error;
      } catch {
        /* not JSON — keep the raw text */
      }

      const after = Number(res.headers.get('Retry-After'));
      const waitSeconds = Number.isFinite(after) && after > 0 ? after : (attempt + 1) * 2;
      // The rate-limit window is a wall-clock hour, so Retry-After can be most of an hour.
      // Waiting that out inside one function call is not on: stop, and let the next
      // scheduled run continue — the backfill marker means nothing is re-read for nothing.
      const canWait = (res.status === 429 || res.status === 503) && waitSeconds <= 90 && attempt < 2;
      if (!canWait) throw new PunchlyError(explain(res.status, code, waitSeconds, message), res.status, code);
      await sleep(waitSeconds * 1000);
    }
  }

  /** The whole roster. Punchly's /staff takes no parameters and returns everyone. */
  async staff(): Promise<PunchlyStaff[]> {
    const page = await this.get('/staff');
    return (page.data ?? []) as PunchlyStaff[];
  }

  /**
   * Every punch between two dates. Paged the way Punchly asks: keep raising the offset
   * until a page comes back shorter than the limit. Rows are deduplicated on record_id,
   * which is stable, in case an edit shifts the ordering underneath the paging.
   */
  async punches(from: string, to: string): Promise<PunchlyPunch[]> {
    const seen = new Map<string, PunchlyPunch>();
    for (let offset = 0; ; offset += PAGE) {
      const page = await this.get('/attendance', { from, to, limit: String(PAGE), offset: String(offset) });
      const rows = (page.data ?? []) as PunchlyPunch[];
      for (const r of rows) seen.set(r.record_id, r);
      // A short page is the last one. The guard is for a server that ignores the limit.
      if (rows.length < PAGE) return [...seen.values()];
      if (offset > 200_000) throw new PunchlyError('Punchly kept returning full pages; stopping rather than looping.', 500);
    }
  }
}

/** What went wrong, in words the owner reads on the settings screen. */
function explain(status: number, code: string | undefined, waitSeconds: number, message: string): string {
  switch (code) {
    case 'invalid_key':
      return 'Punchly does not recognise this key — it is wrong, or it has been revoked. Enter a new one under Setup → Attendance.';
    case 'expired':
      return 'The Punchly key has passed its expiry date. Ask the Punchly admin for a fresh one.';
    case 'missing_scope':
      return 'The key is valid but lacks a scope. It needs attendance:read and staff:read — the Punchly admin can tick them.';
    case 'tenant_inactive':
      return 'The Punchly account is suspended, usually an unpaid subscription. Nothing here can fix that.';
    case 'rate_limited':
      return `Punchly's hourly limit is spent; it frees up in about ${Math.ceil(waitSeconds / 60)} minute(s). The next run carries on from where this one stopped.`;
    case 'range_too_wide':
      return 'Punchly refused the date range as too wide. This is a bug in the sync, not a setting — report it.';
    default:
      if (status === 401) return 'Punchly rejected the request without a key. Check that the key is saved under Setup → Attendance.';
      if (status === 503) return 'Punchly was briefly unavailable. The next run will try again.';
      return `Punchly returned ${status}. ${message}`.trim();
  }
}

/**
 * Split a date range into chunks. A first backfill can be years long; asking for it in one
 * go is a 400, and asking day by day would spend the hourly budget in a fortnight of
 * history. Windows are consecutive — the next starts the day after the last one ended, so
 * there is no gap and no overlap. Both ends are inclusive, and both are matched against
 * Punchly's IST `attendance_date`, so these are working days rather than instants.
 *
 * The default is a quarter, not the 366-day maximum: see BACKFILL_WINDOW_DAYS. Callers may
 * ask for more, up to MAX_SPAN_DAYS, but never beyond it.
 */
export function chunkRange(from: string, to: string, days = BACKFILL_WINDOW_DAYS): Array<{ from: string; to: string }> {
  days = Math.min(days, MAX_SPAN_DAYS - 1);
  const day = 86400000;
  const start = Date.parse(from + 'T00:00:00Z');
  const end = Date.parse(to + 'T00:00:00Z');
  if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) return [];
  const out: Array<{ from: string; to: string }> = [];
  for (let t = start; t <= end; t += (days + 1) * day) {
    const last = Math.min(t + days * day, end);
    out.push({ from: new Date(t).toISOString().slice(0, 10), to: new Date(last).toISOString().slice(0, 10) });
  }
  return out;
}
