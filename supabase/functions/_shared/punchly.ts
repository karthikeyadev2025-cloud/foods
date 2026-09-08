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
const MAX_SPAN_DAYS = 366;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Punchly said no in a way worth repeating to the owner rather than swallowing. */
export class PunchlyError extends Error {
  constructor(message: string, readonly status: number, readonly code?: string) {
    super(message);
  }
}

export class PunchlyClient {
  constructor(private readonly baseUrl: string, private readonly apiKey: string) {}

  private async get(path: string, params: Record<string, string>): Promise<Record<string, unknown>> {
    const url = new URL(this.baseUrl.replace(/\/+$/, '') + path);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);

    // Three tries: a rate limit is a wait, not a failure, and 503 is usually a moment.
    for (let attempt = 0; ; attempt++) {
      const res = await fetch(url, {
        headers: { Authorization: `Bearer ${this.apiKey}`, Accept: 'application/json' },
      });
      if (res.ok) return await res.json();

      const body = await res.text();
      let code: string | undefined;
      try {
        code = (JSON.parse(body) as { error?: string; code?: string }).code ?? (JSON.parse(body) as { error?: string }).error;
      } catch {
        code = undefined;
      }
      const retryable = res.status === 429 || res.status === 503;
      if (!retryable || attempt >= 2) {
        const hint =
          res.status === 401 ? 'Punchly rejected the key — check it under Setup → Attendance.'
          : res.status === 403 ? 'The key is missing the attendance:read / staff:read scopes, or the Punchly account is inactive.'
          : res.status === 429 ? 'Punchly is rate-limiting us; the next run will pick up where this one stopped.'
          : `Punchly returned ${res.status}.`;
        throw new PunchlyError(`${hint} ${body.slice(0, 300)}`.trim(), res.status, code);
      }
      const after = Number(res.headers.get('Retry-After'));
      await sleep(Number.isFinite(after) && after > 0 ? Math.min(after, 30) * 1000 : (attempt + 1) * 2000);
    }
  }

  async staff(): Promise<PunchlyStaff[]> {
    const out: PunchlyStaff[] = [];
    for (let offset = 0; ; offset += PAGE) {
      const page = await this.get('/staff', { limit: String(PAGE), offset: String(offset) });
      const rows = (page.data ?? []) as PunchlyStaff[];
      out.push(...rows);
      if (rows.length < PAGE) return out;
    }
  }

  /** Every punch between two dates, paged out. The caller keeps the span inside the cap. */
  async punches(from: string, to: string): Promise<PunchlyPunch[]> {
    const out: PunchlyPunch[] = [];
    for (let offset = 0; ; offset += PAGE) {
      const page = await this.get('/attendance', { from, to, limit: String(PAGE), offset: String(offset) });
      const rows = (page.data ?? []) as PunchlyPunch[];
      out.push(...rows);
      if (rows.length < PAGE) return out;
    }
  }
}

/**
 * Split a date range into chunks Punchly will accept. A first backfill can be years long;
 * asking for it in one go is a 400, and asking day by day would spend the hourly budget in
 * a fortnight of history.
 */
export function chunkRange(from: string, to: string, days = MAX_SPAN_DAYS - 1): Array<{ from: string; to: string }> {
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
