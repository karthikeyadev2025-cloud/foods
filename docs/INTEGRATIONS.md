# The two outside services

The ERP talks to exactly two things it does not own. They do different jobs and share nothing
but a pattern: the API key lives on the server, never in the browser, and every call goes
through an edge function.

| | **Hey Nikki** | **Punchly** |
| --- | --- | --- |
| What it is | WhatsApp and voice calls to customers | The phone app the staff punch in and out on |
| Direction | The ERP writes (sends), and receives webhooks | The ERP only reads |
| Reaches | Customers | Staff |
| Trigger | Pushed — Nikki calls our webhooks | Polled — Punchly has no webhooks |
| Key lives in | `messaging_settings.api_key` | `punchly_settings.api_key` |
| Functions | `nikki-send`, `nikki-status`, `nikki-inbound`, `run-reminders` | `punchly-sync` |
| Screens | Messaging | Attendance, Setup → Attendance |
| Plan | Full | Growth |

Neither table has a policy for signed-in users, so no browser can read either key however it
asks. The screens read a masked copy through `get_messaging_settings()` / `get_punchly_settings()`,
which return the last four characters and nothing more.

---

## Punchly — attendance

Base `https://punchly.online/api/v1`, bearer token, `attendance:read` and `staff:read` scopes,
**1000 requests an hour per key**. Two endpoints matter:

- `GET /staff` — `user_id`, `staff_id`, `full_name`, `designation`, `branch_name`, `is_active`
- `GET /attendance?from&to&limit&offset` — one row per punch: `record_id`, `staff_id`, `kind`
  (`check_in` / `check_out`), `occurred_at` (UTC), `attendance_date` (already IST),
  `branch_name`, `shift_name`, `latitude`, `longitude`, `enforcement_status`

`limit` is clamped to 1–1000 and a range may not span more than 366 days. 429 arrives with a
`Retry-After` that `_shared/punchly.ts` obeys; 401, 403 and 400 are reported to the owner on the
settings screen instead of being retried.

### Punches are not days

Punchly records events; the ERP wants a register. `upsert_punchly_attendance()` does the fold:

- group by staff and `attendance_date` — **not** by `occurred_at`, whose UTC date puts a night
  shift on the wrong day
- first `check_in` and last `check_out` become the day; the gap between them is the hours
- at or above the full-day hours → present, below → half day; over the full day → overtime
- no check-out at all → present with no hours, and flagged to check
- under the flag hours, or any punch Punchly marked outside its geofence → flagged to check
- the wage follows `staff.daily_wage`: a full day pays it, half a day pays half

Two rules protect the register:

1. **A row somebody typed by hand is never overwritten.** `attendance.source` is `manual` or
   `punchly`; the sync skips every `manual` row and counts them in `kept_manual`.
2. **Every run is an upsert.** Punches arrive late — a phone out of signal at 08:42 delivers at
   19:00 — so the sync always re-reads yesterday as well as today, and a day that gains its
   missing check-out is simply rewritten.

### Who is who

`staff.punchly_user_id` holds Punchly's `user_id`, which is stable. Its `staff_id` (the employee
code) can be renamed by whoever runs Punchly, so it is kept only for display and as a fallback
match. On each sync `upsert_punchly_staff()` links anyone whose name matches an ERP staff member
exactly and unambiguously; two people called SURESH are left for a human, on the list under
Setup → Attendance. **Unmatched punches are skipped, not lost** — matching the person later
brings their whole history in on the next read.

### The schedule

`db/cron/schedule.sql` runs `punchly-sync` at :12 and :42 — two calls per organisation per run,
nowhere near the hourly budget.

- Ordinary run: yesterday and today.
- With `backfill_from` set: history from that date, in chunks of 366 days, moving the marker
  after each chunk (`punchly_advance()`), so a run that dies half way resumes rather than
  starting again. The marker clears itself once it reaches yesterday.

Set the history date once, on the settings screen, when the client wants the past brought in.

### Privacy

Every punch carries GPS. That is personal data under the DPDP Act, so `store_location` is **off**
by default and the coordinates are dropped on the way in. Turn it on only if the client has told
the staff and has a reason to keep it. The `attendance` table is gated on the Payments module,
so a store keeper or production head cannot read anybody's wages or movements; the roster screen,
which rewrites staff rows, is the owner's and the admin's alone.

---

## Hey Nikki — WhatsApp and calls

Covered in the messaging section of `README.md` and in `docs/PROJECT_PLAN.md` §5.1. In short: the
ERP fans out itself so every recipient has its own `message_log` row; `nikki-send` drains the
queue past quiet hours and the daily cap; `nikki-status` and `nikki-inbound` are public webhooks
authenticated by the per-org secret in the URL, not by a JWT. Voice calls ride the same queue on
the channel `ivr_call`. The voice shape in `supabase/functions/_shared/nikki.ts` is the ERP's best
guess until Hey Nikki's voice documentation arrives; only that file and the two webhooks change
when it does.

## Testing either one from here

Neither service can be reached from the development container, so both are proved the same way:
the database side has a full acceptance test that feeds it the exact JSON the edge function would
(`db/tests/17_voice.sql`, `db/tests/19_attendance.sql`), and the HTTP client is a thin, separate
file. The first live run is on the client's Supabase project, and both settings screens show what
the last run did — or what went wrong — in plain words.
