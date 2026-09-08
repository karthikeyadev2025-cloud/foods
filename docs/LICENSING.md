# Licensing — three keys, three plans

One key per organisation. The key decides **whether** the app runs (trial → active →
grace → expired, `db/18_licensing.sql`) and **what** it runs (the plan,
`db/21_plans.sql`). Moving a client up is one command — no reinstall, no new build, and
nothing they have already entered is lost.

## The three plans

Each includes everything in the one before it.

| | Starter | Growth | Full |
| --- | :---: | :---: | :---: |
| **Billing & collection** — items, customers, invoices and prints, receipts, stock on hand, the day's reports, setup, users, permissions | ● | ● | ● |
| **Purchases** — supplier bills, suppliers, purchase returns | | ● | ● |
| **Sales returns** — fresh return, rate difference, damage return | | ● | ● |
| **Payments & accounts** — payments, expenses, cash and bank books, cheques, journal, trial balance, P&L, balance sheet | | ● | ● |
| **Production** — recipes, batches, chief actuals, variance | | ● | ● |
| **Vans & trips** — trips, van loading, loading sheet, settlement | | ● | ● |
| **Quotations & pricing** — quotations, sale and purchase orders, delivery challans, price lists, discount schemes | | ● | ● |
| **WhatsApp & calls** — templates, reminders, broadcasts, inbound orders, reminder and order-taking calls | | | ● |
| **Batches & barcodes** — batch and expiry tracking, barcode labels, godown transfers, stock counts | | | ● |
| **Owner control** — print designer, backup and restore, audit trail | | | ● |
| **Profit & incentives** — route profitability, salesman incentive statements | | | ● |
| **Driver's phone** — van sales, on-the-spot receipts, delivery proof | | | ● |
| **Desktop & offline** — the installed Windows app, working without a connection | | | ● |

**Starter** is a shop that bills and collects. **Growth** is the whole operation on paper.
**Full** is the operation running itself.

## Price ladder

The project is ₹3,80,000, taken in three steps.

| Plan | This step | Paid to date | Share |
| --- | ---: | ---: | ---: |
| Starter | ₹50,000 | ₹50,000 | 13% |
| Growth | ₹1,50,000 | ₹2,00,000 | 39% |
| Full | ₹1,80,000 | ₹3,80,000 | 47% |

Starter is deliberately a low way in: it gets the client billing on the system, off their
old book, and using it every day. Once the counter runs on it, Growth is what makes the
rest of the business legible — buying, paying, accounts, production, vans — and Full is
the part that saves labour rather than recording it: WhatsApp and voice, batches, the
owner tools, the driver's phone, the desktop app. The two upgrades carry 86% of the price
because they carry most of the build.

These figures are not in the code. The plans are what the app enforces; the prices are
whatever you invoice. Renewal after `license_valid_till` — an annual maintenance charge,
say — is a separate commercial matter and is not part of the ₹3,80,000 build price.

## Issuing a key

In the Supabase SQL Editor, which runs as `postgres` and so counts as the vendor.

```sql
-- which organisation?
select id, name, license_plan, license_valid_till from orgs;

-- issue. Prints the key ONCE — copy it, only its hash is stored.
select issue_license(
  '<org id>',            -- organisation
  '2027-09-30',          -- valid till
  'Jyothi Foods, Guntur',-- printed on the licence screen
  3,                     -- devices allowed
  'starter'              -- starter | growth | full
);
```

Give the key to the owner. They enter it under **Setup → Licence** on each PC.

**Upgrading** when the next instalment is paid — the same key keeps working, so there is
nothing to re-enter:

```sql
select set_license_plan('<org id>', 'growth');
```

The app notices within half an hour, or at once if they reload. **Renewing** the date
without touching the plan is `select renew_license('<org id>', '2028-09-30');`.

## What a locked feature actually does

Enforcement is the database's, not the screen's — a locked feature cannot be reached by
hand-made API calls either.

- `can_view` / `can_edit` / `can_delete` test the plan, so every module-gated policy
  already in the app is capped at once.
- Features that live inside a module the plan allows (quotations, batches, the owner
  tools) get a restrictive policy on their own tables: **reads stay, writes stop**.
  Nothing a client entered during the trial disappears, and it all becomes editable again
  the moment the plan opens.
- A whole locked module (purchases, messaging) hides its screens and its rows until the
  plan opens again.
- The functions that run with elevated rights test the plan themselves.

In the app, a locked screen says which plan includes it rather than pretending it does not
exist — the owner should be able to see what the next key buys. Setup → Licence shows all
three plans with ticks and locks.

## Trials

A brand-new organisation is **Full** until its trial runs out (30 days by default,
`orgs.trial_days`), so a prospect sees the whole thing. The key issued afterwards sets
what they actually paid for. To cap an organisation that has not bought yet, issue a key
with the plan, or `set_license_plan` on its own.

## Moving a feature between plans

One array in `db/21_plans.sql`:

```sql
create or replace function plan_features(p_plan text) returns text[] ...
    when 'growth' then array['core', 'purchases', ... ]
```

and the matching copy in `src/lib/permissions.ts` (`FEATURES`), which only decides what to
draw. `db/tests/18_plans.sql` covers the whole ladder.
