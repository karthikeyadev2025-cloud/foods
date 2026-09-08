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

`/attendance` is paged — raise `offset` until a page comes back shorter than `limit` — and rows
are deduplicated on `record_id` on the way through, in case an edit shifts the ordering underneath
the paging. `/staff` takes **no parameters at all** and returns everyone in one response; do not
try to page it.

Every failure is JSON carrying a human `error` and a stable `code`, and the client branches on the
code, never the message: `invalid_key` and `expired` are told to the owner rather than retried
(they will never start working), `missing_scope` names the two scopes, `tenant_inactive` says the
subscription is the problem, and only `rate_limited` and 503 are retried at all.

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
nowhere near the hourly budget. `punchly_due()` decides what each run asks for, in this order:

1. **Backfill** — with `backfill_from` set: history from that date, in chunks of 365 days (the
   cap is 366; the extra day is not worth a `range_too_wide`). `punchly_advance()` moves the
   marker after each chunk, so a run that dies half way resumes rather than starting again, and
   the marker clears itself on reaching yesterday. Set the date once on the settings screen.
2. **Reconcile** — every `reconcile_days` (14 by default), one wider pull. Punchly's own advice:
   a finished day does not change on its own, but an admin can correct it afterwards, and
   nothing else would ever notice.
3. **Ordinary** — yesterday and today.

The rate limit resets on the wall-clock hour, so a `429` can ask for most of an hour. The client
waits only if `Retry-After` is 90 seconds or less; beyond that it stops and lets the next
scheduled run continue, which costs nothing because the marker is where it left off.

### Privacy

Punchly's own documentation is blunt about this, and it is right to be: the API returns personal
data about identifiable employees — names, working hours, and where they were at a given moment.
Moving it into another system needs a lawful basis and a written agreement between the Punchly
customer and whoever processes the data. That is the client's to put in place before the first
sync, not ours, and this paragraph is not legal advice.

What the build does about it:

- **Store the minimum.** Every punch carries GPS. `store_location` is **off** by default and the
  coordinates are dropped on the way in. Turn it on only if the client has told the staff and has
  a reason to keep it.
- **Restrict access inside the ERP too.** `attendance` is gated on the Payments module, so a store
  keeper, a driver or a production head cannot read anybody's wages or movements. The roster
  screen, which rewrites staff rows, is the owner's and the admin's alone.
- **Be able to delete.** `forget_staff_attendance(staff_id)` — owner only, the bin icon on the
  roster — removes every attendance row for one person **and clears their Punchly link**. Without
  that second half the next sync would simply fetch them back; with it, they stay gone until
  somebody deliberately matches them again.
- **Match their retention.** Nothing is kept here that Punchly has dropped, because the ERP only
  ever writes what a fetch returned.

Punchly withholds phone numbers, salaries, bank details, PF and ESI numbers, ID proofs and
selfies by design, so none of that can reach the ERP through this route.

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
