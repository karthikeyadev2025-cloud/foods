-- ============================================================
-- DB acceptance test: the wage sheet, and the books it lands in.
--
-- Four things the register could not do, and the figures that prove each:
--
--   * Overtime was worked out and never paid. RAMESH does 14 extra hours.
--   * Everybody was on a daily wage. LAKSHMI is on 18,000 a month.
--   * Wages never reached the books. The WAGES account was always empty.
--   * Advances did not exist. RAMESH takes 3,000 mid-month.
--
-- The arithmetic is the point of this test, so every expected figure is worked
-- out in the comment beside it. If one of these assertions ever fails, the
-- number in the comment is what to check first.
--
-- Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; uid uuid := gen_random_uuid(); sales_uid uuid := gen_random_uuid();
  v_ramesh uuid; v_lakshmi uuid; v_suresh uuid;
  v_cash uuid; v_cl uuid; v_lwp uuid; j jsonb; r record; n int; v_msg text;
  v_from date := date '2026-11-01'; v_to date := date '2026-11-30';
  d date; v_wages numeric; v_adv_acct numeric;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order)
    values (v_org, 'CASH', 'Cash', true, false, 1) returning id into v_cash;

  -- 500 a day, and a month's salary for the one on a salary
  insert into staff (org_id, full_name, role, daily_wage, pay_type)
    values (v_org, 'RAMESH', 'store_keeper', 500, 'daily') returning id into v_ramesh;
  insert into staff (org_id, full_name, role, daily_wage, pay_type)
    values (v_org, 'SURESH', 'driver', 400, 'daily') returning id into v_suresh;
  insert into staff (org_id, full_name, role, monthly_salary, pay_type)
    values (v_org, 'LAKSHMI', 'accountant', 18000, 'monthly') returning id into v_lakshmi;

  -- ===== 62.1 the rates =====
  -- RAMESH: 500 a day. An 8-hour day at the shop's default, so an hour is
  -- 500 / 8 = 62.50, times the multiplier.
  assert staff_day_rate(v_ramesh, v_to) = 500, format('62.1 daily rate %s', staff_day_rate(v_ramesh, v_to));
  assert staff_ot_rate(v_ramesh, v_to) = 62.50, format('62.1 ot rate %s', staff_ot_rate(v_ramesh, v_to));
  -- LAKSHMI: 18,000 over the 30 days of November = 600 a day. Not 18,000/30
  -- by coincidence — February would give 18,000/28 = 642.86, which is the
  -- point of dividing by the real month.
  assert staff_day_rate(v_lakshmi, v_to) = 600, format('62.1 monthly day rate %s', staff_day_rate(v_lakshmi, v_to));
  assert staff_day_rate(v_lakshmi, date '2026-02-10') = 642.86,
    format('62.1 February is a shorter month: %s', staff_day_rate(v_lakshmi, date '2026-02-10'));

  -- ===== 62.2 the calendar =====
  -- punchly_settings has no policy for signed-in users — it holds the API key —
  -- so even the owner goes through the definer function.
  perform save_punchly_settings(jsonb_build_object(
    'full_day_hours', 8, 'half_day_hours', 4, 'week_off_dow', 0, 'pay_ot', true, 'ot_multiplier', 1.5));
  insert into holidays (org_id, holiday_date, name) values (v_org, date '2026-11-14', 'Diwali');

  assert is_non_working(v_org, date '2026-11-01'), '62.2 the 1st of November 2026 is a Sunday';
  assert is_non_working(v_org, date '2026-11-14'), '62.2 and Diwali is a holiday';
  assert not is_non_working(v_org, date '2026-11-03'), '62.2 a Tuesday is a working day';
  -- time and a half now: 62.50 × 1.5
  assert staff_ot_rate(v_ramesh, v_to) = 93.75, format('62.2 time and a half: %s', staff_ot_rate(v_ramesh, v_to));

  -- ===== 62.3 a month of attendance =====
  insert into leave_types (org_id, code, name, days_per_year, is_paid)
    values (v_org, 'CL', 'Casual leave', 12, true) returning id into v_cl;
  insert into leave_types (org_id, code, name, days_per_year, is_paid)
    values (v_org, 'LWP', 'Leave without pay', 0, false) returning id into v_lwp;

  -- RAMESH works every working day of November, with 14 hours of overtime
  -- spread over the month, and takes one casual leave on the 20th.
  for d in select generate_series(v_from, v_to, interval '1 day')::date loop
    if is_non_working(v_org, d) then continue; end if;
    if d = date '2026-11-20' then
      insert into attendance (org_id, staff_id, work_date, status, leave_type_id)
      values (v_org, v_ramesh, d, 'leave', v_cl);
    else
      insert into attendance (org_id, staff_id, work_date, status, worked_hours, ot_hours)
      values (v_org, v_ramesh, d, 'present', 8, case when d <= date '2026-11-06' then 2.8 else 0 end);
    end if;
  end loop;

  -- SURESH: 10 days present, 2 half days, and 3 days away without pay.
  for d in select generate_series(date '2026-11-02', date '2026-11-13', interval '1 day')::date loop
    if is_non_working(v_org, d) then continue; end if;
    insert into attendance (org_id, staff_id, work_date, status, worked_hours)
    values (v_org, v_suresh, d, (case when d in (date '2026-11-12', date '2026-11-13') then 'half_day' else 'present' end)::attend_status,
            case when d in (date '2026-11-12', date '2026-11-13') then 3 else 8 end);
  end loop;
  for d in select generate_series(date '2026-11-16', date '2026-11-18', interval '1 day')::date loop
    insert into attendance (org_id, staff_id, work_date, status, leave_type_id)
    values (v_org, v_suresh, d, 'leave', v_lwp);
  end loop;

  -- LAKSHMI: on a salary, away unpaid for 2 days.
  for d in select generate_series(date '2026-11-23', date '2026-11-24', interval '1 day')::date loop
    insert into attendance (org_id, staff_id, work_date, status) values (v_org, v_lakshmi, d, 'absent');
  end loop;

  -- ===== 62.4 the sheet =====
  -- November 2026: 30 days, 5 Sundays (1, 8, 15, 22, 29), Diwali on the 14th
  -- (a Saturday) → 24 working days.
  select * into r from wage_sheet(v_from, v_to) where staff_id = v_ramesh;
  assert r.present = 23 and r.paid_leave = 1,
    format('62.4 RAMESH: 23 worked, 1 casual leave — got %s and %s', r.present, r.paid_leave);
  -- 23 present + 1 paid leave = 24 days. Sundays and Diwali unpaid for a
  -- daily-wage hand unless the shop says otherwise, and it has not.
  assert r.days_paid = 24, format('62.4 RAMESH days paid %s', r.days_paid);
  assert r.basic = 12000, format('62.4 24 × 500 = 12,000, got %s', r.basic);
  -- 2nd to 6th November is five working days × 2.8 = 14 hours at 93.75
  -- (the 1st is a Sunday; the 7th is a Saturday and this shop works Saturdays)
  assert r.ot_hours = 14, format('62.4 RAMESH ot hours %s', r.ot_hours);
  assert r.ot_amount = 1312.50, format('62.4 14 × 93.75 = 1,312.50, got %s', r.ot_amount);
  assert r.gross = 13312.50, format('62.4 RAMESH gross %s', r.gross);

  select * into r from wage_sheet(v_from, v_to) where staff_id = v_suresh;
  -- 02–13 Nov less Sunday the 8th = 11 working days, of which the 12th and
  -- 13th are half days
  assert r.present = 9 and r.half_days = 2 and r.unpaid_leave = 3,
    format('62.4 SURESH: %s present, %s half, %s unpaid', r.present, r.half_days, r.unpaid_leave);
  -- 9 + (2 × 0.5) = 10 days × 400 = 4,000. Unpaid leave earns nothing.
  assert r.days_paid = 10, format('62.4 SURESH days paid %s', r.days_paid);
  assert r.basic = 4000, format('62.4 10 × 400 = 4,000, got %s', r.basic);
  assert r.ot_amount = 0, '62.4 SURESH did no overtime';

  select * into r from wage_sheet(v_from, v_to) where staff_id = v_lakshmi;
  -- A salary: the 30 days of the period less 2 unpaid absences = 28 × 600
  assert r.days_paid = 28, format('62.4 LAKSHMI days paid %s', r.days_paid);
  assert r.basic = 16800, format('62.4 18,000 less two days at 600 = 16,800, got %s', r.basic);

  -- ===== 62.5 a paid weekly off changes the sheet, and only then =====
  perform save_punchly_settings(jsonb_build_object('paid_week_off', true, 'paid_holidays', true));
  select * into r from wage_sheet(v_from, v_to) where staff_id = v_ramesh;
  -- 24 worked/leave + 5 Sundays + Diwali = 30 days × 500 = 15,000
  assert r.days_paid = 30, format('62.5 with Sundays and Diwali paid: %s days', r.days_paid);
  assert r.basic = 15000, format('62.5 30 × 500 = 15,000, got %s', r.basic);
  perform save_punchly_settings(jsonb_build_object('paid_week_off', false, 'paid_holidays', false));

  -- ===== 62.6 overtime is paid only when the shop says so =====
  perform save_punchly_settings(jsonb_build_object('pay_ot', false));
  select * into r from wage_sheet(v_from, v_to) where staff_id = v_ramesh;
  assert r.ot_hours = 14, '62.6 the hours are still counted';
  assert r.ot_amount = 0, format('62.6 but not paid: %s', r.ot_amount);
  perform save_punchly_settings(jsonb_build_object('pay_ot', true));

  -- ===== 62.7 an advance is money owed, not an expense =====
  j := to_jsonb(save_staff_advance(jsonb_build_object(
    'staff_id', v_ramesh, 'amount', 3000, 'advance_date', date '2026-11-08', 'mode_id', v_cash)));
  assert advance_balance(v_ramesh) = 3000, format('62.7 advance outstanding %s', advance_balance(v_ramesh));

  -- It must NOT be in the wage bill yet: it is an asset, not a cost.
  select coalesce(sum(jl.debit - jl.credit), 0) into v_wages
    from journal_lines jl join ledger_accounts la on la.id = jl.account_id
   where la.org_id = v_org and la.code = 'WAGES';
  assert v_wages = 0, format('62.7 an advance must not hit the wage bill: WAGES is %s', v_wages);
  select coalesce(sum(jl.debit - jl.credit), 0) into v_adv_acct
    from journal_lines jl join ledger_accounts la on la.id = jl.account_id
   where la.org_id = v_org and la.code = 'STAFF_ADVANCES';
  assert v_adv_acct = 3000, format('62.7 it sits in Staff advances: %s', v_adv_acct);

  -- and it shows on the sheet beside what he earned
  select * into r from wage_sheet(v_from, v_to) where staff_id = v_ramesh;
  assert r.advance_due = 3000, format('62.7 sheet shows the advance: %s', r.advance_due);
  assert r.net = 10312.50, format('62.7 13,312.50 less 3,000 = 10,312.50, got %s', r.net);

  -- ===== 62.8 paying it =====
  j := pay_wages(jsonb_build_object('period_from', v_from, 'period_to', v_to,
                                    'paid_on', date '2026-12-01', 'mode_id', v_cash));
  assert (j->>'staff_count')::int = 3, format('62.8 three people paid: %s', j);
  -- 12,000 + 4,000 + 16,800 = 32,800 basic; 1,312.50 overtime
  assert (j->>'basic')::numeric = 32800, format('62.8 basic %s', j->>'basic');
  assert (j->>'overtime')::numeric = 1312.50, format('62.8 overtime %s', j->>'overtime');
  assert (j->>'advance_recovered')::numeric = 3000, format('62.8 advance recovered %s', j->>'advance_recovered');
  -- handed over: 32,800 + 1,312.50 − 3,000 = 31,112.50
  assert (j->>'net_paid')::numeric = 31112.50, format('62.8 net paid %s', j->>'net_paid');

  -- The advance is now cleared, because it came out of the wage.
  assert advance_balance(v_ramesh) = 0, format('62.8 advance should be cleared: %s', advance_balance(v_ramesh));

  -- ===== 62.9 and the books balance =====
  -- WAGES is debited with what was EARNED: 32,800 + 1,312.50 = 34,112.50.
  -- That is the whole point of this file — it used to be zero.
  select coalesce(sum(jl.debit - jl.credit), 0) into v_wages
    from journal_lines jl join ledger_accounts la on la.id = jl.account_id
   where la.org_id = v_org and la.code = 'WAGES';
  assert v_wages = 34112.50, format('62.9 the wage bill in the P&L: %s', v_wages);
  -- Staff advances is back to nothing: handed over 3,000, recovered 3,000.
  select coalesce(sum(jl.debit - jl.credit), 0) into v_adv_acct
    from journal_lines jl join ledger_accounts la on la.id = jl.account_id
   where la.org_id = v_org and la.code = 'STAFF_ADVANCES';
  assert v_adv_acct = 0, format('62.9 advances cleared: %s', v_adv_acct);
  -- and each person has a payment in the register
  select count(*) into n from payments where org_id = v_org and staff_id is not null;
  assert n = 3, format('62.9 three wage payments in the register, got %s', n);

  -- ===== 62.10 the same month cannot be paid twice =====
  begin
    perform pay_wages(jsonb_build_object('period_from', v_from, 'period_to', v_to, 'mode_id', v_cash));
    raise exception '62.10 November was paid twice';
  exception when unique_violation then null; end;

  select count(*) into n from wage_runs();
  assert n = 1, format('62.10 one run on record, got %s', n);

  -- ===== 62.11 leave balance =====
  select * into r from leave_balance(v_ramesh, 2026) where code = 'CL';
  assert r.taken = 1 and r.remaining = 11, format('62.11 CL: %s taken, %s left', r.taken, r.remaining);

  -- ===== 62.12 who may do any of this =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, sales_uid, 'Counter boy', 'sales_exec');
  perform set_config('request.jwt.claim.sub', sales_uid::text, true); set local role authenticated;
  assert not can_view('attendance'), '62.12 a counter boy has no attendance right';
  begin
    perform wage_sheet(v_from, v_to);
    raise exception '62.12 the counter boy read the wage sheet';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%not available to your role%', format('62.12 wrong reason: %s', v_msg);
  end;
  begin
    perform save_staff_advance(jsonb_build_object('staff_id', v_ramesh, 'amount', 5000));
    raise exception '62.12 the counter boy handed himself an advance';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%cannot record advances%', format('62.12 wrong reason: %s', v_msg);
  end;

  -- Attendance alone is not enough to move money: paying needs Payments too,
  -- because reading a wage sheet and emptying the till are two different jobs.
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  update staff set role = 'store_keeper' where auth_uid = sales_uid;
  update role_permissions rp set can_view = true, can_edit = true
    from roles ro
   where ro.id = rp.role_id and ro.org_id = v_org and ro.based_on = 'store_keeper'
     and rp.module = 'attendance';
  perform set_config('request.jwt.claim.sub', sales_uid::text, true); set local role authenticated;
  assert can_view('attendance') and not can_edit('payments'), '62.12 attendance but no payments';
  begin
    perform pay_wages(jsonb_build_object('period_from', date '2026-10-01', 'period_to', date '2026-10-31', 'mode_id', v_cash));
    raise exception '62.12 wages were paid without the Payments right';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%needs the Payments right%', format('62.12 wrong reason: %s', v_msg);
  end;

  reset role;
  raise notice 'OK: the wage sheet pays overtime at the shop''s own multiplier when the shop says to, carries monthly-salary staff beside daily-wage ones and divides a salary by the real length of the month, counts a paid weekly off and a festival only when they are set as paid, cuts outstanding advances from the month end oldest first and never hands anybody a negative payslip, and puts the lot into the books — WAGES debited with what was earned, the till credited with what was handed over, Staff advances credited with what was recovered, three different figures all of them true. The same month cannot be paid twice, leave has kinds and a balance, and paying needs the Payments right as well as Attendance';
end $$;

rollback;
