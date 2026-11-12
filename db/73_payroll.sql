-- ============================================================
-- JYOTHI FOODS ERP — 73: THE WAGE SHEET IS NOW A WAGE SHEET
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- Four things the register could not do, each of which made the figure at the
-- bottom of the wage sheet wrong rather than merely incomplete:
--
--   1. OVERTIME WAS COUNTED AND NEVER PAID. db/22 works out ot_hours from the
--      punches and stores it, and the wage is a full day or half a day and
--      nothing else. There was no overtime rate anywhere in the database. A
--      shop that pays overtime — which is every shop in this trade at Diwali —
--      has been reading a sheet that is short by every extra hour worked.
--
--   2. EVERYBODY WAS ON A DAILY WAGE. staff.daily_wage was the only figure, so
--      a manager on 18,000 a month could not be put on the sheet at all.
--
--   3. THE WAGES NEVER REACHED THE BOOKS. The WAGES expense account has
--      existed since db/14 and nothing has ever posted to it. The sheet was a
--      report somebody read and then paid by hand, so the P&L had no wages in
--      it and the cash book had a hole the size of the payroll.
--
--   4. ADVANCES DID NOT EXIST. Two thousand rupees on the 8th, cut from the
--      month end — the most ordinary transaction in the factory — had nowhere
--      to be written down.
--
-- And a holiday was a status typed one person-day at a time: no Sunday, no
-- festival list, and `leave` with no kinds and no balance.
--
-- The accounting is kept honest rather than convenient. An advance is not an
-- expense when it is handed over — it is money the person owes back — so it
-- debits STAFF_ADVANCES, an asset. The wage run then debits WAGES with what
-- was EARNED, credits the cash with what was actually HANDED OVER, and credits
-- STAFF_ADVANCES with what was recovered. Three figures that differ, and all
-- three are true.
-- ============================================================

-- ------------------------------------------------------------
-- 1. What the shop pays, and on what terms
-- ------------------------------------------------------------
alter table staff
  -- A daily-wage hand is paid for days worked; a monthly one is paid the
  -- salary less unpaid absence. Keeping them in one column with a flag beats
  -- two tables, because the wage sheet has to add them up together.
  add column if not exists pay_type text not null default 'daily',
  add column if not exists monthly_salary numeric(12,2) not null default 0,
  -- Null means "work it out": the day's rate divided by a full day's hours,
  -- times the shop's overtime multiplier. A figure here overrides that for
  -- somebody paid a flat rate for extra hours.
  add column if not exists ot_rate numeric(12,2);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'staff_pay_type_chk') then
    alter table staff add constraint staff_pay_type_chk check (pay_type in ('daily', 'monthly'));
  end if;
end $$;

-- The payroll rules. These live on punchly_settings because that is the row
-- the Attendance setup screen already edits and because full_day_hours and
-- half_day_hours — which the overtime maths needs — are already on it. The
-- table name is historical: it is the attendance and payroll settings, and
-- most of it has nothing to do with Punchly.
alter table punchly_settings
  -- Off by default on purpose. A shop that has never paid overtime must not
  -- find its wage bill risen the morning after this file is applied; it says
  -- yes once, in Setup, and the sheet changes from then on.
  add column if not exists pay_ot boolean not null default false,
  -- 1.0 = the same rate as ordinary hours, 1.5 = time and a half.
  add column if not exists ot_multiplier numeric(5,2) not null default 1.0,
  -- 0 = Sunday … 6 = Saturday, null = the shop works every day.
  add column if not exists week_off_dow smallint,
  -- Is the weekly off and a festival a paid day for a daily-wage hand? For
  -- monthly staff it always is, by definition of a monthly salary.
  add column if not exists paid_week_off boolean not null default false,
  add column if not exists paid_holidays boolean not null default false;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'punchly_week_off_chk') then
    alter table punchly_settings add constraint punchly_week_off_chk
      check (week_off_dow is null or week_off_dow between 0 and 6);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'punchly_ot_mult_chk') then
    alter table punchly_settings add constraint punchly_ot_mult_chk
      check (ot_multiplier >= 0 and ot_multiplier <= 3);
  end if;
end $$;

comment on table punchly_settings is
  'Attendance and payroll rules for the org: a full day''s hours, the overtime rule, the weekly off, and the Punchly key. Named for Punchly for historical reasons (db/22, db/73).';

alter table attendance
  -- Kept on the row rather than worked out when the sheet is read: the rate
  -- can change, and last March''s sheet must still print last March's figures.
  add column if not exists ot_amount numeric(12,2) not null default 0,
  add column if not exists leave_type_id uuid;

-- ------------------------------------------------------------
-- 2. The calendar: a weekly off and a festival list
-- ------------------------------------------------------------
create table if not exists holidays (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  holiday_date date not null,
  name         text not null,
  is_paid      boolean,          -- null: follow the org's paid_holidays setting
  created_at   timestamptz not null default now(),
  unique (org_id, holiday_date)
);

create index if not exists holidays_org_idx on holidays (org_id, holiday_date);

create table if not exists leave_types (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  code           text not null,
  name           text not null,
  days_per_year  numeric(5,1) not null default 0,
  is_paid        boolean not null default true,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (org_id, code)
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'attendance_leave_type_fk') then
    alter table attendance add constraint attendance_leave_type_fk
      foreign key (leave_type_id) references leave_types(id) on delete set null;
  end if;
end $$;

-- ------------------------------------------------------------
-- 3. Advances
-- ------------------------------------------------------------
create table if not exists staff_advances (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  staff_id      uuid not null references staff(id) on delete cascade,
  advance_date  date not null default current_date,
  amount        numeric(12,2) not null check (amount > 0),
  -- how much of it has been cut from a wage run so far
  recovered     numeric(12,2) not null default 0 check (recovered >= 0),
  mode_id       uuid references receipt_modes(id),
  notes         text,
  created_by    uuid references staff(id),
  created_at    timestamptz not null default now(),
  check (recovered <= amount)
);

create index if not exists staff_advances_staff_idx on staff_advances (staff_id, advance_date);

-- ------------------------------------------------------------
-- 4. A wage run
-- ------------------------------------------------------------
create table if not exists wage_payments (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  period_from  date not null,
  period_to    date not null,
  paid_on      date not null default current_date,
  total_basic  numeric(14,2) not null default 0,
  total_ot     numeric(14,2) not null default 0,
  total_advance numeric(14,2) not null default 0,
  total_net    numeric(14,2) not null default 0,
  staff_count  integer not null default 0,
  notes        text,
  created_by   uuid references staff(id),
  created_at   timestamptz not null default now(),
  check (period_to >= period_from)
);

-- One run per period. A second attempt is refused by the index rather than by
-- a check somebody can forget to write, because paying the same month twice is
-- the one mistake here that costs real money.
create unique index if not exists wage_payments_period_key
  on wage_payments (org_id, period_from, period_to);

create table if not exists wage_payment_lines (
  id          uuid primary key default gen_random_uuid(),
  run_id      uuid not null references wage_payments(id) on delete cascade,
  staff_id    uuid not null references staff(id),
  days        numeric(6,2) not null default 0,
  ot_hours    numeric(8,2) not null default 0,
  basic       numeric(12,2) not null default 0,
  ot_amount   numeric(12,2) not null default 0,
  advance_cut numeric(12,2) not null default 0,
  net_paid    numeric(12,2) not null default 0,
  payment_id  uuid references payments(id),
  unique (run_id, staff_id)
);

-- ------------------------------------------------------------
-- 5. Who may see and touch all this
-- ------------------------------------------------------------
-- Wages are the attendance module, as db/27 settled: who may see what people
-- are paid is a different question from who may see the cash book. The plan
-- gate is the same one db/22 put on attendance, so these ride in Starter.
do $$
declare t text;
begin
  foreach t in array array['holidays', 'leave_types', 'staff_advances', 'wage_payments'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists org_read on %I', t);
    execute format('drop policy if exists mod_insert on %I', t);
    execute format('drop policy if exists mod_update on %I', t);
    execute format('drop policy if exists mod_delete on %I', t);
    execute format('create policy org_read on %I for select using (org_id = my_org_id() and can_view(''attendance''))', t);
    execute format('create policy mod_insert on %I for insert with check (org_id = my_org_id() and can_edit(''attendance''))', t);
    execute format('create policy mod_update on %I for update using (org_id = my_org_id() and can_edit(''attendance'')) with check (org_id = my_org_id() and can_edit(''attendance''))', t);
    execute format('create policy mod_delete on %I for delete using (org_id = my_org_id() and can_delete(''attendance''))', t);
    execute format('drop policy if exists plan_insert on %I', t);
    execute format('drop policy if exists plan_update on %I', t);
    execute format('drop policy if exists plan_delete on %I', t);
    execute format('create policy plan_insert on %I as restrictive for insert with check (has_feature(''attendance''))', t);
    execute format('create policy plan_update on %I as restrictive for update using (has_feature(''attendance''))', t);
    execute format('create policy plan_delete on %I as restrictive for delete using (has_feature(''attendance''))', t);
  end loop;
end $$;

-- The lines hang off the run, so they are reached through it.
alter table wage_payment_lines enable row level security;
drop policy if exists child_scope on wage_payment_lines;
create policy child_scope on wage_payment_lines for all
  using (exists (select 1 from wage_payments w where w.id = run_id and w.org_id = my_org_id() and can_view('attendance')))
  with check (exists (select 1 from wage_payments w where w.id = run_id and w.org_id = my_org_id() and can_edit('attendance')));

grant select, insert, update, delete on holidays, leave_types, staff_advances, wage_payments, wage_payment_lines to authenticated;

-- ------------------------------------------------------------
-- 6. The arithmetic, in one place
-- ------------------------------------------------------------
/** The payroll rules for an org, with sane values when the row is missing. */
create or replace function payroll_rules(p_org uuid)
returns table (full_day_hours numeric, half_day_hours numeric, auto_wage boolean,
               pay_ot boolean, ot_multiplier numeric, week_off_dow smallint,
               paid_week_off boolean, paid_holidays boolean)
language sql stable security definer set search_path = public as $$
  select coalesce(s.full_day_hours, 8), coalesce(s.half_day_hours, 4), coalesce(s.auto_wage, true),
         coalesce(s.pay_ot, false), coalesce(s.ot_multiplier, 1.0), s.week_off_dow,
         coalesce(s.paid_week_off, false), coalesce(s.paid_holidays, false)
    from (select p_org as org) x
    left join punchly_settings s on s.org_id = x.org;
$$;

/**
 * What one ordinary day is worth to this person.
 *
 * A monthly salary is divided by the days in the month the date falls in, not
 * by 30: February is not a worse month to be ill in than March, and a sheet
 * that says otherwise is the kind of thing people notice on their payslip.
 */
create or replace function staff_day_rate(p_staff uuid, p_date date default current_date)
returns numeric language sql stable security definer set search_path = public as $$
  select case
    when s.pay_type = 'monthly'
      then round(coalesce(s.monthly_salary, 0) / extract(day from (date_trunc('month', p_date) + interval '1 month - 1 day'))::numeric, 2)
    else coalesce(s.daily_wage, 0)
  end
  from staff s where s.id = p_staff;
$$;

/** What an overtime hour is worth. A rate on the person wins; else derived. */
create or replace function staff_ot_rate(p_staff uuid, p_date date default current_date)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(
    (select s.ot_rate from staff s where s.id = p_staff and s.ot_rate is not null),
    round(staff_day_rate(p_staff, p_date)
            / nullif((select full_day_hours from payroll_rules(
                       (select org_id from staff where id = p_staff))), 0)
            * (select ot_multiplier from payroll_rules((select org_id from staff where id = p_staff))), 2),
    0);
$$;

/** Is this a day the shop is shut? */
create or replace function is_non_working(p_org uuid, p_date date)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from holidays h where h.org_id = p_org and h.holiday_date = p_date)
      or (select week_off_dow from payroll_rules(p_org)) = extract(dow from p_date)::smallint;
$$;

grant execute on function payroll_rules(uuid) to authenticated;
grant execute on function staff_day_rate(uuid, date) to authenticated;
grant execute on function staff_ot_rate(uuid, date) to authenticated;
grant execute on function is_non_working(uuid, date) to authenticated;

-- ------------------------------------------------------------
-- 7. What is still owed on advances
-- ------------------------------------------------------------
create or replace function advance_balance(p_staff uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(a.amount - a.recovered), 0)
    from staff_advances a
   where a.staff_id = p_staff and a.org_id = my_org_id();
$$;

/**
 * Hand somebody an advance against their wages.
 *
 * It is NOT an expense: it is money they owe back, so it debits
 * STAFF_ADVANCES. Writing it to WAGES here and again at the month end — which
 * is what calling save_payment would do — would double the wage bill in the
 * P&L and nobody would notice until the year end.
 */
create or replace function save_staff_advance(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid; v_staff uuid := nullif(p->>'staff_id', '')::uuid;
        v_amt numeric := round(coalesce((p->>'amount')::numeric, 0), 2);
        v_date date := coalesce(nullif(p->>'advance_date', '')::date, current_date);
        m receipt_modes%rowtype; v_acct uuid; v_name text;
begin
  if v_org is null then raise exception 'Organisation not known'; end if;
  if not can_edit('attendance') then raise exception 'Your role cannot record advances'; end if;
  perform require_feature('attendance');
  if v_amt <= 0 then raise exception 'The advance must be more than zero'; end if;
  select full_name into v_name from staff where id = v_staff and org_id = v_org;
  if v_name is null then raise exception 'Staff member not found'; end if;

  perform ensure_payroll_accounts(v_org);
  select * into m from receipt_modes where id = nullif(p->>'mode_id', '')::uuid and org_id = v_org;

  insert into staff_advances (org_id, staff_id, advance_date, amount, mode_id, notes, created_by)
  values (v_org, v_staff, v_date, v_amt, m.id, nullif(p->>'notes', ''), my_staff_id())
  returning id into v_id;

  -- The money leaving, if they said which till it left. Without a mode the
  -- advance is still recorded and recovered — a shop that pays from a pocket
  -- and sorts the cash book out later is not a reason to lose the deduction.
  if m.id is not null then
    v_acct := money_account(v_org, m.code, m.account_id, nullif(p->>'account_id', '')::uuid);
    perform post_money(v_org, v_acct, v_date, -v_amt, format('Advance to %s', v_name), 'staff_advances', v_id);
    perform post_journal(v_org, v_date, format('Advance to %s', v_name), 'staff_advances', v_id,
      jsonb_build_array(
        jsonb_build_object('account', 'STAFF_ADVANCES', 'debit', v_amt),
        jsonb_build_object('account', money_code(v_acct), 'credit', v_amt, 'narration', m.code)));
  end if;
  return v_id;
end $$;

/** The asset account an advance sits in until it is cut from a wage. */
create or replace function ensure_payroll_accounts(p_org uuid) returns void
language sql as $$
  insert into ledger_accounts (org_id, code, name, type, is_system)
  values (p_org, 'STAFF_ADVANCES', 'Staff advances', 'asset', true)
  on conflict (org_id, name) do nothing;
$$;

grant execute on function advance_balance(uuid) to authenticated;
grant execute on function save_staff_advance(jsonb) to authenticated;

-- ------------------------------------------------------------
-- 8. The wage sheet
-- ------------------------------------------------------------
/**
 * Days, hours and money per person for a period — the sheet somebody actually
 * pays from.
 *
 * Replaces attendance_summary's figures rather than adding to them: that one
 * summed attendance.wage_amount, which carries a full day or half a day and
 * never a paisa of overtime. Here the overtime is paid when the shop says to
 * pay it, monthly staff are paid a salary less unpaid absence, and what is
 * still owed on advances is shown beside the earnings so the person writing
 * the cheque can see both.
 *
 * Paid leave and paid holidays are counted as days earned; unpaid ones are
 * not. A daily-wage hand gets nothing for a Sunday unless the shop says
 * Sundays are paid, which is the custom in this trade and is a tick box.
 */
create or replace function wage_sheet(p_from date, p_to date)
returns table (staff_id uuid, full_name text, role staff_role, role_name text,
               pay_type text, day_rate numeric, ot_rate numeric,
               present integer, half_days integer, paid_leave integer, unpaid_leave integer,
               absent integer, holidays integer, week_offs integer,
               days_paid numeric, worked_hours numeric, ot_hours numeric,
               basic numeric, ot_amount numeric, gross numeric,
               advance_due numeric, net numeric, needs_review integer)
language plpgsql stable security definer set search_path = public as $$
declare v_org uuid := my_org_id(); rules record;
begin
  if not can_view('attendance') then raise exception 'The wage sheet is not available to your role'; end if;
  perform require_feature('attendance');
  if p_to < p_from then raise exception 'The period ends before it starts'; end if;
  select * into rules from payroll_rules(v_org);

  return query
  with days as (
    -- Every date in the period, said once, with what kind of day it is. The
    -- calendar is the truth about holidays and weekly offs, not a row somebody
    -- remembered to type into the register.
    select d::date as work_date,
           exists (select 1 from holidays h where h.org_id = v_org and h.holiday_date = d::date) as is_holiday,
           coalesce(rules.week_off_dow = extract(dow from d)::smallint, false) as is_week_off,
           (select h.is_paid from holidays h where h.org_id = v_org and h.holiday_date = d::date) as holiday_paid
      from generate_series(p_from, p_to, interval '1 day') d
  ),
  per_staff as (
    select st.id,
           st.full_name,
           st.role,
           r.name as role_name,
           st.pay_type,
           st.is_mestry,
           -- The rate as at the END of the period: a month is paid at one rate.
           staff_day_rate(st.id, p_to) as day_rate,
           staff_ot_rate(st.id, p_to) as ot_rate,
           count(a.id) filter (where a.status = 'present')::int as present,
           count(a.id) filter (where a.status = 'half_day')::int as half_days,
           count(a.id) filter (where a.status = 'leave' and coalesce(lt.is_paid, false))::int as paid_leave,
           count(a.id) filter (where a.status = 'leave' and not coalesce(lt.is_paid, false))::int as unpaid_leave,
           count(a.id) filter (where a.status = 'absent')::int as absent,
           coalesce(sum(a.worked_hours), 0) as worked_hours,
           coalesce(sum(a.ot_hours), 0) as ot_hours,
           count(a.id) filter (where a.needs_review)::int as needs_review
      from staff st
      left join roles r on r.id = st.role_id
      left join attendance a on a.staff_id = st.id and a.work_date between p_from and p_to
      left join leave_types lt on lt.id = a.leave_type_id
     where st.org_id = v_org and st.is_active
     group by st.id, st.full_name, st.role, r.name, st.pay_type, st.is_mestry
  ),
  calendar as (
    select count(*) filter (where is_holiday)::int as holidays,
           count(*) filter (where is_week_off and not is_holiday)::int as week_offs,
           count(*) filter (where is_holiday and coalesce(holiday_paid, rules.paid_holidays))::int as paid_holidays,
           count(*) filter (where is_week_off and not is_holiday and rules.paid_week_off)::int as paid_week_offs,
           count(*)::int as period_days
      from days
  )
  select ps.id, ps.full_name, ps.role, ps.role_name, ps.pay_type,
         ps.day_rate, ps.ot_rate,
         ps.present, ps.half_days, ps.paid_leave, ps.unpaid_leave, ps.absent,
         cal.holidays, cal.week_offs,
         d.days_paid,
         round(ps.worked_hours, 2), round(ps.ot_hours, 2),
         d.basic,
         d.ot_amount,
         round(d.basic + d.ot_amount, 2) as gross,
         advance_balance(ps.id) as advance_due,
         -- An advance bigger than the month's earnings is recovered only as
         -- far as the earnings go; the rest stays owing. Nobody is ever handed
         -- a negative payslip.
         round(greatest(d.basic + d.ot_amount - advance_balance(ps.id), 0), 2) as net,
         ps.needs_review
    from per_staff ps
    cross join calendar cal
    cross join lateral (
      select
        case when ps.pay_type = 'monthly'
             -- A salary, less the days they were away unpaid.
             then round(greatest(cal.period_days - ps.absent - ps.unpaid_leave, 0)::numeric, 2)
             -- cal.paid_holidays has already applied each holiday's own
             -- is_paid, falling back to the shop's setting, so it is simply
             -- added here.
             else round(ps.present + ps.half_days * 0.5 + ps.paid_leave
                        + cal.paid_holidays + cal.paid_week_offs, 2)
        end as days_paid
    ) dp
    cross join lateral (
      select dp.days_paid,
             -- The same multiplication either way: a monthly salary has
             -- already been divided into a day rate, and days_paid is the
             -- days earned on whichever terms this person is on.
             round(ps.day_rate * dp.days_paid, 2) as basic,
             case when rules.pay_ot then round(ps.ot_hours * ps.ot_rate, 2) else 0 end as ot_amount
    ) d
   order by ps.full_name;
end $$;

grant execute on function wage_sheet(date, date) to authenticated;

-- ------------------------------------------------------------
-- 9. Paying it, into the books
-- ------------------------------------------------------------
/**
 * Pay a period's wages.
 *
 * Needs the attendance right to read the sheet AND the payments right to move
 * the money, because those are two different jobs and in most shops two
 * different people. The run is recorded line by line so the sheet can be
 * reprinted exactly as it was paid, and the period is unique so the same month
 * cannot be paid twice — the one mistake here that costs real money.
 *
 * Three postings per person, and they are deliberately not the same figure:
 *
 *   debit  WAGES           what they EARNED
 *   credit cash/bank       what was HANDED OVER
 *   credit STAFF_ADVANCES  what was RECOVERED from earlier advances
 *
 * The cash movement and the payments row come from save_payment, so a wage
 * payment appears in the payments register and the cash book like any other.
 */
create or replace function pay_wages(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := my_org_id(); v_run uuid;
  v_from date := nullif(p->>'period_from', '')::date;
  v_to date := nullif(p->>'period_to', '')::date;
  v_paid date := coalesce(nullif(p->>'paid_on', '')::date, current_date);
  v_mode uuid := nullif(p->>'mode_id', '')::uuid;
  v_acct uuid := nullif(p->>'account_id', '')::uuid;
  r record; a record; v_cut numeric; v_left numeric; v_pay uuid;
  v_basic numeric := 0; v_ot numeric := 0; v_adv numeric := 0; v_net numeric := 0; v_n integer := 0;
begin
  if v_org is null then raise exception 'Organisation not known'; end if;
  if not can_view('attendance') then raise exception 'The wage sheet is not available to your role'; end if;
  if not can_edit('payments') then
    raise exception 'Paying the wages needs the Payments right as well as Attendance';
  end if;
  perform require_feature('attendance');
  if v_from is null or v_to is null then raise exception 'Give the period to pay'; end if;
  if v_mode is null then raise exception 'Choose how the wages were paid'; end if;
  perform ensure_payroll_accounts(v_org);

  insert into wage_payments (org_id, period_from, period_to, paid_on, notes, created_by)
  values (v_org, v_from, v_to, v_paid, nullif(p->>'notes', ''), my_staff_id())
  returning id into v_run;

  for r in select * from wage_sheet(v_from, v_to) loop
    if r.gross <= 0 and r.advance_due <= 0 then continue; end if;

    -- Recover the oldest advances first, and only as far as the earnings go.
    v_cut := least(r.advance_due, r.gross);
    v_left := v_cut;
    for a in select * from staff_advances
              where staff_id = r.staff_id and org_id = v_org and amount > recovered
              order by advance_date, created_at loop
      exit when v_left <= 0;
      update staff_advances
         set recovered = recovered + least(v_left, a.amount - a.recovered)
       where id = a.id;
      v_left := v_left - least(v_left, a.amount - a.recovered);
    end loop;

    v_pay := null;
    if r.gross - v_cut > 0 then
      v_pay := save_payment(jsonb_build_object(
        'staff_id', r.staff_id, 'amount', r.gross - v_cut, 'payment_date', v_paid,
        'mode_id', v_mode, 'account_id', v_acct,
        'narration', format('Wages %s to %s', to_char(v_from, 'DD-MM-YYYY'), to_char(v_to, 'DD-MM-YYYY'))));
    end if;

    -- The part of the wage that went to clearing an advance never touches the
    -- till: the money left when the advance was handed over. This is the entry
    -- that turns the advance back from an asset into an expense.
    if v_cut > 0 then
      perform post_journal(v_org, v_paid,
        format('Advance recovered from %s''s wages', r.full_name), 'wage_payments', v_run,
        jsonb_build_array(
          jsonb_build_object('account', 'WAGES', 'debit', v_cut),
          jsonb_build_object('account', 'STAFF_ADVANCES', 'credit', v_cut)));
    end if;

    insert into wage_payment_lines (run_id, staff_id, days, ot_hours, basic, ot_amount, advance_cut, net_paid, payment_id)
    values (v_run, r.staff_id, r.days_paid, r.ot_hours, r.basic, r.ot_amount, v_cut, r.gross - v_cut, v_pay);

    v_basic := v_basic + r.basic;
    v_ot := v_ot + r.ot_amount;
    v_adv := v_adv + v_cut;
    v_net := v_net + (r.gross - v_cut);
    v_n := v_n + 1;
  end loop;

  update wage_payments
     set total_basic = v_basic, total_ot = v_ot, total_advance = v_adv,
         total_net = v_net, staff_count = v_n
   where id = v_run;

  return jsonb_build_object('run_id', v_run, 'staff_count', v_n, 'basic', v_basic,
                            'overtime', v_ot, 'advance_recovered', v_adv, 'net_paid', v_net);
end $$;

grant execute on function pay_wages(jsonb) to authenticated;

/** Was this period already paid? The screen asks before it offers the button. */
create or replace function wage_runs()
returns table (id uuid, period_from date, period_to date, paid_on date,
               total_basic numeric, total_ot numeric, total_advance numeric,
               total_net numeric, staff_count integer, created_by_name text)
language sql stable security definer set search_path = public as $$
  select w.id, w.period_from, w.period_to, w.paid_on, w.total_basic, w.total_ot,
         w.total_advance, w.total_net, w.staff_count, s.full_name
    from wage_payments w
    left join staff s on s.id = w.created_by
   where w.org_id = my_org_id() and can_view('attendance')
   order by w.period_to desc, w.created_at desc;
$$;

grant execute on function wage_runs() to authenticated;

-- ------------------------------------------------------------
-- 10. Leave balance
-- ------------------------------------------------------------
create or replace function leave_balance(p_staff uuid, p_year integer default null)
returns table (leave_type_id uuid, code text, name text, days_per_year numeric,
               taken numeric, remaining numeric)
language sql stable security definer set search_path = public as $$
  select lt.id, lt.code, lt.name, lt.days_per_year,
         coalesce(t.taken, 0),
         greatest(lt.days_per_year - coalesce(t.taken, 0), 0)
    from leave_types lt
    left join (
      select a.leave_type_id, count(*)::numeric as taken
        from attendance a
       where a.staff_id = p_staff and a.status = 'leave'
         and extract(year from a.work_date) = coalesce(p_year, extract(year from current_date))
       group by a.leave_type_id
    ) t on t.leave_type_id = lt.id
   where lt.org_id = my_org_id() and lt.is_active and can_view('attendance')
   order by lt.code;
$$;

grant execute on function leave_balance(uuid, integer) to authenticated;

-- ------------------------------------------------------------
-- 11. The leftover from before attendance was its own module
-- ------------------------------------------------------------
-- db/27 moved attendance out of the payments module and updated the policies
-- and the read functions, but upsert_punchly_attendance was missed and still
-- asks for can_edit('payments'). The sync itself runs as the service so it has
-- never failed, which is why nobody noticed; a call from inside the app would
-- be refused for a reason that is no longer true.
CREATE OR REPLACE FUNCTION public.upsert_punchly_attendance(p_org uuid, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s punchly_settings%rowtype; rec record; v_written int := 0; v_kept int := 0; v_skipped int := 0;
        v_status attend_status; v_hours numeric; v_wage numeric; v_ot numeric;
begin
  if not is_service_call() and (p_org is distinct from my_org_id() or not can_edit('attendance')) then
    raise exception 'Not allowed to sync this organisation';
  end if;
  select * into s from punchly_settings where org_id = p_org;
  if not found then raise exception 'Punchly is not set up for this organisation'; end if;

  for rec in
    with punch as (
      select x->>'staff_id' as code,
             nullif(x->>'punchly_user_id', '') as user_id,
             (x->>'attendance_date')::date as work_date,
             x->>'kind' as kind,
             (x->>'occurred_at')::timestamptz as at,
             nullif(x->>'branch_name', '') as branch_name,
             nullif(x->>'shift_name', '') as shift_name,
             nullif(x->>'latitude', '')::numeric as lat,
             nullif(x->>'longitude', '')::numeric as lon,
             coalesce(x->>'enforcement_status', 'ok') as enforcement
        from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x)
    select st.id as staff_id, st.daily_wage, p.work_date,
           min(p.at) filter (where p.kind = 'check_in') as first_in,
           max(p.at) filter (where p.kind = 'check_out') as last_out,
           count(*) as punches,
           (array_agg(p.branch_name) filter (where p.branch_name is not null))[1] as branch_name,
           (array_agg(p.shift_name) filter (where p.shift_name is not null))[1] as shift_name,
           (array_agg(p.lat) filter (where p.lat is not null))[1] as lat,
           (array_agg(p.lon) filter (where p.lon is not null))[1] as lon,
           bool_or(p.enforcement <> 'ok') as flagged
      from punch p
      join staff st on st.org_id = p_org
       and (st.punchly_user_id = p.user_id or (p.user_id is null and st.punchly_staff_id = p.code))
     group by st.id, st.daily_wage, p.work_date
  loop
    -- a row somebody typed by hand is the truth; the sync never argues with it
    if exists (select 1 from attendance a where a.staff_id = rec.staff_id and a.work_date = rec.work_date and a.source = 'manual') then
      v_kept := v_kept + 1;
      continue;
    end if;
    if rec.first_in is null and rec.last_out is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_hours := case when rec.first_in is not null and rec.last_out is not null and rec.last_out > rec.first_in
                    then round(extract(epoch from rec.last_out - rec.first_in) / 3600.0, 2) end;
    -- no check-out at all: they came, the phone did not record them leaving
    v_status := case when v_hours is null then 'present'
                     when v_hours >= s.full_day_hours then 'present'
                     else 'half_day' end;
    v_ot := case when v_hours is not null and v_hours > s.full_day_hours then round(v_hours - s.full_day_hours, 2) else 0 end;
    v_wage := case when not s.auto_wage then 0
                   when v_status = 'present' then coalesce(rec.daily_wage, 0)
                   else round(coalesce(rec.daily_wage, 0) / 2, 2) end;

    insert into attendance (org_id, staff_id, work_date, status, source,
                            in_time, out_time, first_in_at, last_out_at, worked_hours, ot_hours, wage_amount,
                            punches, branch_name, shift_name, latitude, longitude, needs_review, updated_at)
    values (p_org, rec.staff_id, rec.work_date, v_status, 'punchly',
            (rec.first_in at time zone 'Asia/Kolkata')::time, (rec.last_out at time zone 'Asia/Kolkata')::time,
            rec.first_in, rec.last_out, v_hours, v_ot, v_wage,
            rec.punches, rec.branch_name, rec.shift_name,
            case when s.store_location then rec.lat end, case when s.store_location then rec.lon end,
            rec.flagged or v_hours is null or (v_hours is not null and v_hours < s.half_day_hours), now())
    on conflict (staff_id, work_date) do update set
      status = excluded.status, source = 'punchly',
      in_time = excluded.in_time, out_time = excluded.out_time,
      first_in_at = excluded.first_in_at, last_out_at = excluded.last_out_at,
      worked_hours = excluded.worked_hours, ot_hours = excluded.ot_hours, wage_amount = excluded.wage_amount,
      punches = excluded.punches, branch_name = excluded.branch_name, shift_name = excluded.shift_name,
      latitude = excluded.latitude, longitude = excluded.longitude,
      needs_review = excluded.needs_review, updated_at = now();
    v_written := v_written + 1;
  end loop;

  update punchly_settings set last_sync_at = now(),
         last_sync_note = format('%s written, %s hand-typed rows kept, %s without a usable punch', v_written, v_kept, v_skipped)
   where org_id = p_org;
  return jsonb_build_object('written', v_written, 'kept_manual', v_kept, 'skipped', v_skipped);
end $function$;

-- ------------------------------------------------------------
-- 12. The new tables go in the backup
-- ------------------------------------------------------------
-- Appended at the end: holidays and leave types are referenced by attendance,
-- and attendance is already late in the list, so these have to land before it.
-- Rather than guess, they go in just ahead of 'attendance'.
-- The whole list again with the new tables in place: leave types, holidays and
-- advances ahead of 'attendance', which references them, and the wage run at
-- the end. Spelled out rather than computed, because a function cannot read
-- its own previous result and the restore order is the one thing in a backup
-- that must not be clever.
create or replace function snapshot_tables() returns text[]
language sql immutable as $$
  select array[
    'roles', 'uoms', 'pack_types', 'item_categories', 'sections', 'items', 'item_price_overrides',
    'price_lists', 'price_list_items:price_list_id:price_lists', 'discount_schemes', 'item_barcodes', 'routes',
    'customers', 'suppliers', 'stock_locations', 'vehicles', 'expense_heads', 'cash_bank_accounts',
    'receipt_modes', 'number_series', 'role_permissions', 'ledger_accounts', 'recipes',
    'recipe_ingredients:recipe_id:recipes', 'production_batches',
    'batch_ingredients:batch_id:production_batches', 'item_batches', 'vehicle_trips', 'invoices',
    'invoice_items:invoice_id:invoices', 'inbound_orders', 'quotations',
    'quotation_items:quotation_id:quotations', 'orders', 'order_items:order_id:orders', 'order_fulfilments',
    'delivery_challans', 'challan_items:challan_id:delivery_challans', 'purchases',
    'purchase_items:purchase_id:purchases', 'purchase_returns',
    'purchase_return_items:return_id:purchase_returns', 'sales_returns',
    'sales_return_items:return_id:sales_returns', 'receipts', 'receipt_lines:receipt_id:receipts',
    'receipt_allocations:receipt_id:receipts', 'payments', 'cheques', 'account_transfers', 'stock_transfers',
    'stock_transfer_items:transfer_id:stock_transfers', 'stock_counts',
    'stock_count_items:count_id:stock_counts', 'stock_ledger', 'journal_entries',
    'journal_lines:entry_id:journal_entries', 'account_transactions', 'message_templates', 'reminder_rules',
    'catalogs', 'broadcasts', 'new_stock_rules', 'message_log', 'transaction_message_settings',
    'messaging_settings', 'punchly_settings', 'print_templates', 'leave_types', 'holidays', 'staff_advances',
    'attendance', 'staff', 'wage_payments', 'wage_payment_lines:run_id:wage_payments'
  ];
$$;

-- ------------------------------------------------------------
-- 13. The settings screen learns the payroll rules
-- ------------------------------------------------------------
-- punchly_settings has no policy for signed-in users at all — the API key must
-- never be readable from the browser — so these two definer functions are the
-- only way in and out, and the new columns have to be added to both or the
-- screen cannot set them.
create or replace function get_punchly_settings() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s punchly_settings%rowtype;
begin
  if not can_view('attendance') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  insert into punchly_settings (org_id) values (v_org) on conflict (org_id) do nothing;
  select * into s from punchly_settings where org_id = v_org;
  return jsonb_build_object(
    'is_enabled', s.is_enabled, 'api_url', s.api_url,
    'has_api_key', s.api_key is not null,
    'api_key_hint', case when s.api_key is null then null else '••••' || right(s.api_key, 4) end,
    'full_day_hours', s.full_day_hours, 'half_day_hours', s.half_day_hours,
    'auto_wage', s.auto_wage, 'store_location', s.store_location,
    'reconcile_days', s.reconcile_days, 'last_reconcile_at', s.last_reconcile_at,
    'backfill_from', s.backfill_from, 'last_sync_at', s.last_sync_at, 'last_sync_note', s.last_sync_note,
    -- db/73
    'pay_ot', s.pay_ot, 'ot_multiplier', s.ot_multiplier, 'week_off_dow', s.week_off_dow,
    'paid_week_off', s.paid_week_off, 'paid_holidays', s.paid_holidays);
end $$;

create or replace function save_punchly_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not can_edit('attendance') then raise exception 'Your role cannot change the attendance settings'; end if;
  perform require_feature('attendance');
  insert into punchly_settings (org_id) values (my_org_id()) on conflict (org_id) do nothing;
  update punchly_settings set
    api_url        = coalesce(nullif(p->>'api_url', ''), api_url),
    api_key        = case when nullif(p->>'api_key', '') is not null then p->>'api_key' else api_key end,
    is_enabled     = coalesce((p->>'is_enabled')::boolean, is_enabled),
    full_day_hours = coalesce(nullif(p->>'full_day_hours', '')::numeric, full_day_hours),
    half_day_hours = coalesce(nullif(p->>'half_day_hours', '')::numeric, half_day_hours),
    auto_wage      = coalesce((p->>'auto_wage')::boolean, auto_wage),
    store_location = coalesce((p->>'store_location')::boolean, store_location),
    reconcile_days = coalesce(nullif(p->>'reconcile_days', '')::integer, reconcile_days),
    backfill_from  = case when p ? 'backfill_from' then nullif(p->>'backfill_from', '')::date else backfill_from end,
    -- db/73. week_off_dow is sent as '' to mean "the shop works every day",
    -- so it is asked whether the key is PRESENT rather than coalesced — a
    -- coalesce could never clear it.
    pay_ot         = coalesce((p->>'pay_ot')::boolean, pay_ot),
    ot_multiplier  = coalesce(nullif(p->>'ot_multiplier', '')::numeric, ot_multiplier),
    week_off_dow   = case when p ? 'week_off_dow' then nullif(p->>'week_off_dow', '')::smallint else week_off_dow end,
    paid_week_off  = coalesce((p->>'paid_week_off')::boolean, paid_week_off),
    paid_holidays  = coalesce((p->>'paid_holidays')::boolean, paid_holidays),
    updated_at     = now()
  where org_id = my_org_id();
  return get_punchly_settings();
end $$;

-- ------------------------------------------------------------
-- 14. The users screen reads and writes the new pay terms
-- ------------------------------------------------------------
-- monthly_salary and ot_rate are wage figures, so they are masked exactly as
-- daily_wage is (db/71) — and because db/71's grant names every column it
-- allows rather than every column it forbids, these two are not readable from
-- the staff table by anyone signed in without anybody having to remember to
-- revoke them. That was the point of writing the grant that way round.
drop function if exists staff_list();
create or replace function staff_list()
returns table (id uuid, org_id uuid, auth_uid uuid, full_name text, phone text, role staff_role,
               daily_wage numeric, is_mestry boolean, is_active boolean, created_at timestamptz,
               punchly_user_id text, punchly_staff_id text, designation text,
               role_id uuid, role_name text,
               pay_type text, monthly_salary numeric, ot_rate numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_wages boolean := can_view('attendance') or can_view('setup');
begin
  if my_org_id() is null then return; end if;
  return query
    select s.id, s.org_id, s.auth_uid, s.full_name, s.phone, s.role,
           case when v_wages then s.daily_wage end,
           s.is_mestry, s.is_active, s.created_at,
           s.punchly_user_id, s.punchly_staff_id, s.designation,
           s.role_id, r.name,
           s.pay_type,
           case when v_wages then s.monthly_salary end,
           case when v_wages then s.ot_rate end
      from staff s
      left join roles r on r.id = s.role_id
     where s.org_id = my_org_id()
     order by s.full_name;
end $$;

grant execute on function staff_list() to authenticated;

-- save_staff learns the pay terms. Everything else is db/72's, unchanged.
create or replace function save_staff(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p->>'id', '')::uuid;
        v_role_id uuid := nullif(p->>'role_id', '')::uuid; v_role staff_role; r roles%rowtype;
        v_pay text := nullif(p->>'pay_type', '');
begin
  if v_org is null then raise exception 'Organisation not known'; end if;
  if not has_role('owner', 'admin') then raise exception 'Only an owner or admin can change staff'; end if;
  if v_pay is not null and v_pay not in ('daily', 'monthly') then
    raise exception 'Somebody is paid by the day or on a monthly salary, not %', v_pay;
  end if;

  if v_role_id is not null then
    select * into r from roles where id = v_role_id and org_id = v_org;
    if not found then raise exception 'Role not found'; end if;
    v_role := r.based_on;
  else
    v_role := coalesce(nullif(p->>'role', '')::staff_role, 'sales_exec');
  end if;
  if my_role() = 'admin' and v_role in ('owner', 'admin') then
    raise exception 'An admin cannot make somebody an owner or a manager';
  end if;

  if v_id is null then
    insert into staff (org_id, full_name, phone, role, role_id, daily_wage, is_mestry, is_active, designation,
                       pay_type, monthly_salary, ot_rate)
    values (v_org, nullif(trim(p->>'full_name'), ''), nullif(trim(p->>'phone'), ''), v_role, v_role_id,
            coalesce(nullif(p->>'daily_wage', '')::numeric, 0),
            coalesce((p->>'is_mestry')::boolean, false),
            coalesce((p->>'is_active')::boolean, true),
            nullif(trim(p->>'designation'), ''),
            coalesce(v_pay, 'daily'),
            coalesce(nullif(p->>'monthly_salary', '')::numeric, 0),
            nullif(p->>'ot_rate', '')::numeric)
    returning id into v_id;
    return v_id;
  end if;

  update staff set
    full_name      = coalesce(nullif(trim(p->>'full_name'), ''), full_name),
    phone          = case when p ? 'phone' then nullif(trim(p->>'phone'), '') else phone end,
    role_id        = case when v_role_id is not null then v_role_id else role_id end,
    role           = case when p ? 'role' or v_role_id is not null then v_role else role end,
    daily_wage     = case when p ? 'daily_wage' then coalesce(nullif(p->>'daily_wage', '')::numeric, 0) else daily_wage end,
    is_mestry      = case when p ? 'is_mestry' then coalesce((p->>'is_mestry')::boolean, false) else is_mestry end,
    is_active      = case when p ? 'is_active' then coalesce((p->>'is_active')::boolean, true) else is_active end,
    designation    = case when p ? 'designation' then nullif(trim(p->>'designation'), '') else designation end,
    pay_type       = coalesce(v_pay, pay_type),
    monthly_salary = case when p ? 'monthly_salary' then coalesce(nullif(p->>'monthly_salary', '')::numeric, 0) else monthly_salary end,
    -- ot_rate is nullable on purpose — null means "work it out" — so it is
    -- asked whether the key is present rather than coalesced.
    ot_rate        = case when p ? 'ot_rate' then nullif(p->>'ot_rate', '')::numeric else ot_rate end
   where id = v_id and org_id = v_org;
  if not found then raise exception 'Staff member not found'; end if;
  return v_id;
end $$;

grant execute on function save_staff(jsonb) to authenticated;
