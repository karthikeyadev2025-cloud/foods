# Desktop app, licensing and offline (T11)

The desktop app is the same web build inside an Electron window. It talks to Supabase
exactly as the browser does; the shell only adds a stable device id, a single-instance
lock, external-link handling and the installer.

## Build the Windows installer

```bash
npm install
npm run desktop:dist          # → release/Jyothi Foods ERP-Setup-<version>.exe
```

What that runs:

| Step | Command | Output |
| --- | --- | --- |
| Renderer | `cross-env VITE_DESKTOP=1 vite build` | `dist/` with relative asset paths (loaded from `file://`) |
| Shell | `tsc -p tsconfig.electron.json` | `dist-electron/main.js`, `dist-electron/preload.cjs` |
| Installer | `electron-builder --win` | NSIS installer, per-user, desktop + start-menu shortcuts |

Put an icon at `build/icon.ico` (256×256) before building; without it electron-builder
uses the Electron icon and warns.

**The installer does not need to carry your project.** If `.env` is present at build time
its values are baked in and the app goes straight to the sign-in screen. If it is not, the
app asks once on first run for the Project URL and the anon public key (Supabase →
Settings → API) and keeps them on that machine. That means **one installer works on every
PC and for any project** — hand the same `.exe` around and type the two lines once per
computer. "Connect to a different database" under the sign-in button clears them again.

The anon key is safe to type there: every table is behind row-level security, so the key
alone opens nothing. The service role key must never be entered — the app rejects it.

### Building without Wine (Linux / macOS)

`electron-builder` needs Wine on a non-Windows machine to stamp the icon and version onto
the `.exe`. Without it the build still leaves a complete, runnable app in
`release/win-unpacked/` — zip that folder and it works as a portable copy, just with the
default Electron icon. Install Wine (`apt-get install -y wine wine64`) to get the real
NSIS installer.

Development: run `npm run dev` in one terminal and `npm run desktop:dev` in another.
The shell then loads `http://localhost:5173` with DevTools open.

### Code signing

Unsigned installers trigger the SmartScreen "unknown publisher" screen on first run.
To sign, get an Authenticode certificate (an OV/EV code-signing cert from a CA, or Azure
Trusted Signing) and set two environment variables before `npm run desktop:dist`:

```
CSC_LINK=C:\certs\jyothi-foods.pfx      (path, or the base64 of the file)
CSC_KEY_PASSWORD=<pfx password>
```

electron-builder signs `Jyothi Foods ERP.exe` and the installer with SHA-256. For an EV
certificate on a hardware token, sign on the machine that holds the token. Nothing in
the repository changes between a signed and an unsigned build.

## Licensing (`db/18_licensing.sql`)

One licence per organisation, activated on each device. Only a SHA-256 of the key is
stored in `orgs.license_key`; the key itself is shown once when issued.

**Issue a key** (vendor, in the Supabase SQL Editor — it runs as `postgres`, which counts
as the service role):

```sql
select issue_license('<org id>', '2027-09-30', 'Jyothi Foods, Guntur', 3);
-- returns e.g. JF-7K2QF-9DM1A-X3P0C-QW8ZL   ← give this to the owner, keep no copy needed
select renew_license('<org id>', '2028-09-30');          -- move the date later
select * from license_state('<org id>');                  -- what the app will see
```

The org id is on Setup → Business profile in the browser address bar of the audit trail,
or `select id, name from orgs;`.

**States** (`license_status()` — checked at start, on focus and every 30 minutes):

| Status | When | App |
| --- | --- | --- |
| trial | no key, within `trial_days` (30) of the org's creation | normal, banner in the last 7 days |
| unlicensed | no key, trial over | **read-only** |
| active | today ≤ `license_valid_till` | normal, banner in the last 14 days |
| grace | lapsed ≤ `license_grace_days` (7) | normal, amber banner |
| expired | lapsed beyond the grace days | **read-only** |

Read-only means every screen, report, print and Excel export still works and nothing new
can be made. The UI turns every edit right off (`usePermissions().readOnly`); the database
enforces it on its own with `enforce_license()` before insert on the document header
tables (invoices, receipts, payments, purchases, returns, quotations, orders, challans,
production batches, stock transfers and counts, account transfers, trips, stock ledger).
Scheduled jobs and backups run with the service role and are never blocked.

**Devices**: the owner or an admin types the key under Setup → Licence on each machine.
Each activation registers the device (`license_devices`, up to `license_max_devices`);
the owner can remove one to free a slot. The desktop app's device id is a uuid in
`%APPDATA%\Jyothi Foods ERP\device.json`; the browser keeps one in localStorage.

## Offline

**Reads**: the TanStack Query cache is persisted to IndexedDB (`app/providers.tsx`), so
every screen opened while online shows its last data without a connection, for up to
24 hours. A screen never opened online has nothing to show.

**Writes**: the document-creating saves (invoice, receipt, payment, purchase, sales and
purchase return, quotation, order, challan, stock transfer) go through `queuedRpc()` in
`src/lib/supabase.ts`. With no connection, or when the request itself fails, the call is
written to the **outbox** (IndexedDB) and the user sees "Saved to the outbox". When the
connection returns the outbox is replayed in the order it was written — automatically on
the `online` event and at start-up, or by hand from the bar at the top or the Outbox
page. A queued item that the database rejects (a validation error, a lapsed licence)
stays in the outbox with its error for the user to retry or discard; nothing is dropped
silently.

Not queued: status changes, conversions, cancellations, master edits and settings —
those need the live row and simply fail offline with the usual error toast.

Sign-in itself needs a connection; an existing session keeps working offline until its
token can no longer be refreshed.
