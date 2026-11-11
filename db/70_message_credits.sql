-- ============================================================
-- JYOTHI FOODS ERP — 70: PREPAID MESSAGE CREDITS
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- The shop is to buy credits from the supplier of this software and spend one
-- per WhatsApp message. Credits are money: once a shop has paid for them, the
-- count has to be defensible six months later when somebody says "I bought ten
-- thousand and you have sent four thousand, where are the rest".
--
-- So this is a LEDGER, not a balance. Every credit bought and every credit
-- spent is a row saying how many, why, and what it was for, and the balance is
-- the sum of them. A single number that is incremented and decremented can be
-- wrong with nothing to compare it against; a ledger can always be read back
-- line by line, which is the only way that argument ever ends.
--
-- Three rules the money depends on:
--
--   * A credit is spent when a message is CLAIMED for sending, in the same
--     statement that claims it, under the row lock that claim already takes.
--     Charging after the provider answers would let a crash between the two
--     send messages nobody paid for; charging before, in a separate statement,
--     would let two senders running at once spend the same last credit twice.
--
--   * Sending stops at zero. Not a warning, not an overdraft: the queue simply
--     stops being claimed, and the messages wait. A shop that has run out has
--     not lost anything — the reminders go when it tops up.
--
--   * Nothing here is written from the app. Credits are added by the supplier
--     (service role) or by a verified payment, and the ledger is append-only
--     to everyone else.
-- ============================================================

create table if not exists credit_ledger (
  id          bigserial primary key,
  org_id      uuid not null references orgs(id) on delete cascade,
  -- + bought, − spent. Never zero; a row that changes nothing is noise.
  delta       integer not null check (delta <> 0),
  reason      text not null,
  -- what it was for: a message_log id when spent, a top-up id when bought
  ref_table   text,
  ref_id      uuid,
  note        text,
  created_at  timestamptz not null default now()
);

create index if not exists credit_ledger_org_idx on credit_ledger (org_id, created_at desc);
-- One message is charged once, however many times the sender is restarted.
create unique index if not exists credit_ledger_once_per_message
  on credit_ledger (ref_table, ref_id) where ref_table = 'message_log';

alter table credit_ledger enable row level security;
drop policy if exists credit_ledger_read on credit_ledger;
create policy credit_ledger_read on credit_ledger for select
  using (org_id = my_org_id());
-- No insert, update or delete policy on purpose: the app can read its own
-- ledger and can never write to it.

create or replace function credit_balance(p_org uuid default null) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(sum(delta), 0)::integer
    from credit_ledger
   where org_id = coalesce(p_org, my_org_id());
$$;

grant execute on function credit_balance(uuid) to authenticated;
grant select on credit_ledger to authenticated;

-- ------------------------------------------------------------
-- Buying credits
-- ------------------------------------------------------------
create table if not exists credit_topups (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  credits        integer not null check (credits > 0),
  -- in paise, so there is never a rounding argument about a rupee figure
  amount_paise   bigint not null check (amount_paise >= 0),
  rate_paise     integer not null,              -- what one credit cost on the day
  provider       text not null default 'razorpay',
  order_id       text,
  payment_id     text,
  status         text not null default 'paid' check (status in ('created', 'paid', 'failed')),
  note           text,
  created_at     timestamptz not null default now()
);

-- The webhook is retried by the payment provider until it gets a 200, so the
-- same payment WILL arrive more than once. This is what stops it being paid
-- for twice.
create unique index if not exists credit_topups_payment_key
  on credit_topups (provider, payment_id) where payment_id is not null;

alter table credit_topups enable row level security;
drop policy if exists credit_topups_read on credit_topups;
create policy credit_topups_read on credit_topups for select
  using (org_id = my_org_id());

grant select on credit_topups to authenticated;

/**
 * Add credits. Supplier side only — the service role, which is what a verified
 * payment webhook runs as, or the SQL editor for a top-up taken by hand.
 *
 * Idempotent on the payment id: calling it twice for one payment returns the
 * first top-up and adds nothing, because a payment provider retrying a webhook
 * must not mint credits.
 */
create or replace function add_credits(
  p_org uuid, p_credits integer, p_amount_paise bigint default 0,
  p_payment_id text default null, p_order_id text default null,
  p_provider text default 'razorpay', p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_rate integer; v_existing uuid;
begin
  if not is_service_call() then
    raise exception 'Credits are added by the supplier only' using errcode = '42501';
  end if;
  if p_credits <= 0 then raise exception 'Credits must be more than zero'; end if;
  if not exists (select 1 from orgs where id = p_org) then raise exception 'Organisation not found'; end if;

  if p_payment_id is not null then
    select id into v_existing from credit_topups
     where provider = p_provider and payment_id = p_payment_id;
    if v_existing is not null then
      -- Already counted. Say so plainly rather than quietly doing nothing,
      -- so a webhook retry is distinguishable from a lost payment.
      return jsonb_build_object('topup_id', v_existing, 'credits_added', 0,
                                'balance', credit_balance(p_org), 'already_counted', true);
    end if;
  end if;

  v_rate := case when p_credits > 0 then (p_amount_paise / p_credits)::integer else 0 end;
  insert into credit_topups (org_id, credits, amount_paise, rate_paise, provider, order_id, payment_id, status, note)
  values (p_org, p_credits, p_amount_paise, v_rate, p_provider, p_order_id, p_payment_id, 'paid', p_note)
  returning id into v_id;

  insert into credit_ledger (org_id, delta, reason, ref_table, ref_id, note)
  values (p_org, p_credits, 'top-up', 'credit_topups', v_id, p_note);

  return jsonb_build_object('topup_id', v_id, 'credits_added', p_credits,
                            'balance', credit_balance(p_org), 'already_counted', false);
end $$;

revoke execute on function add_credits(uuid, integer, bigint, text, text, text, text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- Money that arrives without a name on it
-- ------------------------------------------------------------
-- A payment reaches the webhook with the shop's id in the payment notes,
-- because the supplier makes one payment link or QR per shop. If that is
-- missing — somebody paid against the wrong link, the notes were dropped, a
-- shop scanned a QR meant for another — the payment must not be thrown away
-- and must not be guessed at either. It is parked here, where it can be seen
-- and attributed by hand, and the webhook still answers 200 so the provider
-- stops retrying a payment that is safely recorded.
create table if not exists credit_payments_unmatched (
  id            uuid primary key default gen_random_uuid(),
  provider      text not null default 'razorpay',
  payment_id    text not null,
  amount_paise  bigint not null,
  payload       jsonb,
  assigned_org  uuid references orgs(id),
  assigned_at   timestamptz,
  created_at    timestamptz not null default now()
);

create unique index if not exists credit_payments_unmatched_key
  on credit_payments_unmatched (provider, payment_id);

alter table credit_payments_unmatched enable row level security;
-- No policy at all: this is the supplier's own tray. A shop has no business
-- reading other shops' payments, and nothing in the app reads it.

/**
 * Attribute a parked payment to a shop and give it the credits. Supplier only.
 * Idempotent: a payment already assigned returns what it bought the first time.
 */
create or replace function assign_unmatched_payment(
  p_payment_id text, p_org uuid, p_rate_paise integer default 90, p_provider text default 'razorpay'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare u credit_payments_unmatched%rowtype; v_credits integer; j jsonb;
begin
  if not is_service_call() then
    raise exception 'Payments are attributed by the supplier only' using errcode = '42501';
  end if;
  if p_rate_paise <= 0 then raise exception 'The rate per credit must be more than zero'; end if;
  select * into u from credit_payments_unmatched
   where provider = p_provider and payment_id = p_payment_id;
  if not found then raise exception 'No parked payment %', p_payment_id; end if;

  v_credits := (u.amount_paise / p_rate_paise)::integer;
  if v_credits <= 0 then
    raise exception 'Rs %.2f at % paise a credit does not buy one credit',
      (u.amount_paise / 100.0), p_rate_paise;
  end if;

  -- add_credits is idempotent on the payment id, so a second call here adds
  -- nothing even if the row was somehow assigned twice.
  j := add_credits(p_org, v_credits, u.amount_paise, p_payment_id, null, p_provider,
                   'attributed by hand from an unmatched payment');
  update credit_payments_unmatched
     set assigned_org = p_org, assigned_at = coalesce(assigned_at, now())
   where id = u.id;
  return j || jsonb_build_object('payment_id', p_payment_id, 'org_id', p_org);
end $$;

revoke execute on function assign_unmatched_payment(text, uuid, integer, text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- Spending them: the send gate
-- ------------------------------------------------------------
-- Same function as db/25, with the credit balance added as a third limit
-- beside the quiet hours and the daily cap. The spend happens in the SAME
-- statement that claims the messages, so two senders running at once cannot
-- both spend the last credit, and a sender that dies after claiming has
-- already paid for what it claimed.
create or replace function claim_queued_messages(p_org uuid, p_limit int default 50)
returns setof message_log language plpgsql security definer set search_path = public as $$
declare s messaging_settings%rowtype; v_now time; v_sent_today int; v_credits int; v_take int;
begin
  if not is_service_call() then raise exception 'Sender only'; end if;
  select * into s from messaging_settings where org_id = p_org;
  if not found or not s.is_enabled or s.api_key is null then return; end if;
  v_now := (now() at time zone 'Asia/Kolkata')::time;
  if (s.quiet_from > s.quiet_to and (v_now >= s.quiet_from or v_now < s.quiet_to))
     or (s.quiet_from < s.quiet_to and v_now >= s.quiet_from and v_now < s.quiet_to) then
    return;
  end if;
  select count(*) into v_sent_today from message_log
   where org_id = p_org
     and sent_at >= (((now() at time zone 'Asia/Kolkata')::date)::timestamp at time zone 'Asia/Kolkata');
  if v_sent_today >= s.daily_cap then return; end if;

  -- Out of credits: the queue is left alone and the messages wait. Nothing is
  -- dropped, nothing is marked failed — a shop that tops up tomorrow sends
  -- today's reminders tomorrow.
  v_credits := credit_balance(p_org);
  if v_credits <= 0 then return; end if;

  v_take := least(p_limit, s.daily_cap - v_sent_today, v_credits);
  if v_take <= 0 then return; end if;

  return query
    with claimed as (
      update message_log set attempts = attempts + 1, updated_at = now(), not_before = null
       where id in (select id from message_log
                     where org_id = p_org and status = 'queued' and attempts < 3
                       and (not_before is null or not_before <= now())
                       and (channel <> 'ivr_call' or s.voice_enabled)
                     order by created_at limit v_take)
      returning *
    ),
    charged as (
      insert into credit_ledger (org_id, delta, reason, ref_table, ref_id)
      select org_id, -1, 'message', 'message_log', id from claimed
      -- A retry of a message already paid for is not charged again.
      on conflict (ref_table, ref_id) where ref_table = 'message_log' do nothing
      returning 1
    )
    select * from claimed;
end $$;

-- ------------------------------------------------------------
-- The changeover: nobody's reminders stop on the day this is applied
-- ------------------------------------------------------------
-- Until now messages cost nothing, so every existing shop has a balance of
-- zero — and the gate above would stop their reminders dead the moment this
-- file is run. That is not a decision to make by accident, so each shop that
-- already has messaging switched on is given an opening balance to carry it
-- over until it tops up.
--
-- 100 credits is a starting figure; change it to whatever the free allowance
-- is before running this. It is given once per shop: re-running this file adds
-- nothing, because a shop with any ledger row at all is skipped.
insert into credit_ledger (org_id, delta, reason, note)
select s.org_id, 100, 'opening balance',
       'free allowance when credits came in; messages were not charged before this'
  from messaging_settings s
 where s.is_enabled
   and not exists (select 1 from credit_ledger c where c.org_id = s.org_id);

comment on table credit_ledger is
  'Every message credit bought and spent. The balance is the sum of it; there is no separate balance to disagree with (db/70).';
