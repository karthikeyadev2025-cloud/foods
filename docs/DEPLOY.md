# Putting the app on the web (Vercel)

The app is a static build that talks to Supabase from the browser, so any static host
works. `vercel.json` in the repository root already sets the build, the single-page
rewrites and the caching, so Vercel needs nothing but the two environment variables.

## First deploy

1. Go to vercel.com, sign in with GitHub, **Add New → Project**.
2. Pick `karthikeyadev2025-cloud/foods`. Vercel reads `vercel.json` and fills in the
   framework (Vite), build command (`npm run build`) and output directory (`dist`).
   Leave them as they are.
3. Open **Environment Variables** and add these three, for Production, Preview and
   Development alike:

   | Name | Value |
   | --- | --- |
   | `VITE_SUPABASE_URL` | `https://djtvbyasxmlsjtpxbond.supabase.co` |
   | `VITE_SUPABASE_ANON_KEY` | the anon **public** key from Supabase → Settings → API |
   | `ELECTRON_SKIP_BINARY_DOWNLOAD` | `1` |

   The anon key is meant to be public: every table is behind row-level security, so a
   key on its own opens nothing. The service role key must **never** go here.
   `ELECTRON_SKIP_BINARY_DOWNLOAD` stops the install from fetching the 100 MB desktop
   binary the web build has no use for.
4. **Deploy**. About a minute later you get an address like
   `https://foods-xxxx.vercel.app`.

Every push to `main` redeploys by itself. A push to any other branch gets its own
preview address, which is a safe place to try a change before it reaches the client.

## After the first deploy

- **Tell the app where it lives.** Setup → Business profile → *App web address*: paste
  the Vercel address. Document links in WhatsApp messages are built from it, so the
  "attach the document" switch does nothing until it is set.
- **Supabase needs no CORS change.** It accepts any origin with a valid anon key.
- **The phone.** Open the address in Chrome on the driver's phone, then *Add to home
  screen*. It installs as an app and opens on `/m`, the driver screens. Drivers land
  there on sign-in whichever way they open it.

## Custom domain

In the Vercel project, **Settings → Domains**, add e.g. `erp.jyothifoods.in` and copy
the CNAME record it shows into the domain's DNS. The certificate is issued
automatically. Update the App web address on the business profile afterwards.

## What is not on Vercel

- **Edge functions** (`supabase/functions/`) live on Supabase, not here. Deploy them
  with the Supabase CLI as `docs/DESKTOP.md` and the Messaging settings screen say.
- **The database.** Migrations are run in the Supabase SQL Editor, in number order.
- **The desktop installer** is built on a Windows machine (`docs/DESKTOP.md`). The
  desktop app and the web address are the same code and the same data; a shop can use
  either.

## If a deploy fails

Open the failed deploy in Vercel and read the build log.

- `Missing VITE_SUPABASE_URL` in the browser, not the build: the variables were added
  after the build. Redeploy from the Deployments tab.
- Install step downloading Electron for minutes: `ELECTRON_SKIP_BINARY_DOWNLOAD` is
  missing or misspelled.
- A blank page with a 404 on a sub-page such as `/invoices`: `vercel.json` was not
  picked up. Check it sits in the repository root on the deployed commit.
