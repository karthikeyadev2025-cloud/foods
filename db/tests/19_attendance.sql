-- ============================================================
-- DB acceptance test: attendance and the Punchly sync. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
revoke execute on function set_license_plan(uuid, text) from authenticated;

do $$
declare
  v_org uuid; v_ramesh uuid; v_laxmi uuid; v_suresh1 uuid; v_suresh2 uuid;
  d1 date := current_date - 2; d2 date := current_date - 1;
  j jsonb; r record; n int; v_punches jsonb;
  uid_owner uuid := gen_random_uuid();
  uid_acct uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into staff (org_id, full_name, role, daily_wage) values (v_org, 'RAMESH', 'store_keeper', 600) returning id into v_ramesh;
  insert into staff (org_id, full_name, role, daily_wage, is_mestry) values (v_org, 'LAXMI', 'chief', 500, true) returning id into v_laxmi;
  insert into staff (org_id, full_name, role, daily_wage) values (v_org, 'SURESH', 'chief', 450) returning id into v_suresh1;
  insert into staff (org_id, full_name, role, daily_wage) values (v_org, 'SURESH', 'production_head', 700) returning id into v_suresh2;
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_acct, 'ACCOUNTANT', 'accountant');

  -- ===== the key is a server secret: the browser cannot read the table at all =====
  j := save_punchly_settings(jsonb_build_object('api_key', 'pk_live_abcdefghijklmnop1234', 'is_enabled', true, 'backfill_from', (d1 - 5)::text));
  assert (j->>'has_api_key')::boolean and j->>'api_key_hint' = '••••1234', format('masked %s', j);
  assert not (j ? 'api_key'), 'the raw key must never come back to the screen';
  select count(*) into n from punchly_settings; assert n = 0, 'punchly_settings must be unreadable to a signed-in user';
  begin
    perform punchly_due();
    assert false, 'a signed-in user must not be able to ask for the raw key';
  exception when others then null; end;

  -- ===== the roster: one exact name links itself, two of the same name do not =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  j := upsert_punchly_staff(v_org, jsonb_build_array(
        jsonb_build_object('user_id', 'u-ram', 'staff_id', 'EMP01', 'full_name', 'Ramesh', 'designation', 'Godown in-charge'),
        jsonb_build_object('user_id', 'u-lax', 'staff_id', 'EMP02', 'full_name', 'Lakshmi Devi'),
        jsonb_build_object('user_id', 'u-sur', 'staff_id', 'EMP03', 'full_name', 'SURESH')));
  assert (j->>'matched_by_name')::int = 1 and (j->>'unmatched_count')::int = 2, format('roster %s', j);
  select punchly_user_id as uid, punchly_staff_id as code, designation as desig into r from staff where id = v_ramesh;
  assert r.uid = 'u-ram' and r.code = 'EMP01' and r.desig = 'Godown in-charge', format('ramesh %s', to_jsonb(r));
  select count(*) into n from staff where punchly_user_id is not null; assert n = 1, 'only the unambiguous name is linked';

  -- the two left over are matched by hand, from the screen
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  perform link_punchly_staff(v_laxmi, 'u-lax', 'EMP02');
  perform link_punchly_staff(v_suresh2, 'u-sur', 'EMP03');
  select count(*) into n from staff where punchly_user_id is not null; assert n = 3;

  -- ===== punches fold into one row a day =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  v_punches := jsonb_build_array(
    -- RAMESH: a full day with an hour and a half over
    jsonb_build_object('punchly_user_id', 'u-ram', 'staff_id', 'EMP01', 'attendance_date', d1, 'kind', 'check_in',
                       'occurred_at', ((d1 + time '09:00') at time zone 'Asia/Kolkata'), 'branch_name', 'Guntur', 'shift_name', 'General',
                       'latitude', 16.3067, 'longitude', 80.4365, 'enforcement_status', 'ok'),
    jsonb_build_object('punchly_user_id', 'u-ram', 'staff_id', 'EMP01', 'attendance_date', d1, 'kind', 'check_out',
                       'occurred_at', ((d1 + time '18:30') at time zone 'Asia/Kolkata'), 'branch_name', 'Guntur', 'enforcement_status', 'ok'),
    -- LAXMI: three hours, which is short even for half a day
    jsonb_build_object('punchly_user_id', 'u-lax', 'staff_id', 'EMP02', 'attendance_date', d1, 'kind', 'check_in',
                       'occurred_at', ((d1 + time '10:00') at time zone 'Asia/Kolkata'), 'enforcement_status', 'ok'),
    jsonb_build_object('punchly_user_id', 'u-lax', 'staff_id', 'EMP02', 'attendance_date', d1, 'kind', 'check_out',
                       'occurred_at', ((d1 + time '13:00') at time zone 'Asia/Kolkata'), 'enforcement_status', 'ok'),
    -- RAMESH yesterday: came in, the phone never recorded him leaving
    jsonb_build_object('punchly_user_id', 'u-ram', 'staff_id', 'EMP01', 'attendance_date', d2, 'kind', 'check_in',
                       'occurred_at', ((d2 + time '08:45') at time zone 'Asia/Kolkata'), 'enforcement_status', 'outside_geofence'));
  j := upsert_punchly_attendance(v_org, v_punches);
  assert (j->>'written')::int = 3, format('fold %s', j);

  select status::text as st, in_time, out_time, worked_hours, ot_hours, wage_amount, punches as np, branch_name, shift_name, needs_review, source, latitude
    into r from attendance where staff_id = v_ramesh and work_date = d1;
  assert r.st = 'present' and r.in_time = '09:00' and r.out_time = '18:30' and r.worked_hours = 9.5 and r.ot_hours = 1.5
     and r.wage_amount = 600 and r.np = 2 and r.branch_name = 'Guntur' and r.shift_name = 'General'
     and not r.needs_review and r.source = 'punchly', format('ramesh d1 %s', to_jsonb(r));
  assert r.latitude is null, 'GPS is not kept unless the client asks for it';

  select status::text as st, worked_hours, wage_amount, needs_review into r from attendance where staff_id = v_laxmi and work_date = d1;
  assert r.st = 'half_day' and r.worked_hours = 3 and r.wage_amount = 250 and r.needs_review, format('laxmi d1 %s', to_jsonb(r));

  select status::text as st, worked_hours, out_time, wage_amount, needs_review into r from attendance where staff_id = v_ramesh and work_date = d2;
  assert r.st = 'present' and r.worked_hours is null and r.out_time is null and r.wage_amount = 600 and r.needs_review,
         format('ramesh d2, no check-out %s', to_jsonb(r));

  -- ===== the same punches again change nothing; a late one completes the day =====
  j := upsert_punchly_attendance(v_org, v_punches);
  assert (j->>'written')::int = 3, 'a re-read is an upsert, not a duplicate';
  select count(*) into n from attendance; assert n = 3, format('still three rows, found %s', n);

  v_punches := v_punches || jsonb_build_array(
        jsonb_build_object('punchly_user_id', 'u-ram', 'staff_id', 'EMP01', 'attendance_date', d2, 'kind', 'check_out',
                           'occurred_at', ((d2 + time '17:15') at time zone 'Asia/Kolkata'), 'enforcement_status', 'ok'));
  j := upsert_punchly_attendance(v_org, v_punches);
  select worked_hours, out_time, ot_hours, needs_review into r from attendance where staff_id = v_ramesh and work_date = d2;
  -- the day is complete, but he punched in from outside the geofence, so it still wants a look
  assert r.worked_hours = 8.5 and r.out_time = '17:15' and r.ot_hours = 0.5 and r.needs_review,
         format('the late punch closed the day %s', to_jsonb(r));

  -- ===== a row typed by hand wins, for ever =====
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  perform save_attendance(jsonb_build_object('staff_id', v_laxmi, 'work_date', d1, 'status', 'leave', 'notes', 'Told the mestry in the morning'));
  select status::text as st, source, wage_amount, needs_review into r from attendance where staff_id = v_laxmi and work_date = d1;
  assert r.st = 'leave' and r.source = 'manual' and r.wage_amount = 0 and not r.needs_review, format('manual %s', to_jsonb(r));

  reset role; perform set_config('request.jwt.claim.sub', '', true);
  j := upsert_punchly_attendance(v_org, v_punches);
  assert (j->>'kept_manual')::int = 1, format('the sync must leave hand-typed rows alone %s', j);
  select status::text as st, source into r from attendance where staff_id = v_laxmi and work_date = d1;
  assert r.st = 'leave' and r.source = 'manual', 'the hand-typed leave survived the sync';

  -- ===== GPS only when the client turns it on =====
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  perform save_punchly_settings(jsonb_build_object('store_location', true));
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform upsert_punchly_attendance(v_org, v_punches);
  select latitude, longitude into r from attendance where staff_id = v_ramesh and work_date = d1;
  assert r.latitude = 16.306700 and r.longitude = 80.436500, format('GPS once asked for %s', to_jsonb(r));

  -- ===== what the sync asks for: history first, then today and yesterday =====
  select org_id, from_date, to_date, is_backfill, api_key into r from punchly_due();
  assert r.org_id = v_org and r.from_date = d1 - 5 and r.to_date = current_date and r.is_backfill
     and r.api_key = 'pk_live_abcdefghijklmnop1234', format('backfill due %s', to_jsonb(r));
  perform punchly_advance(v_org, d1 - 3);
  select from_date, is_backfill into r from punchly_due();
  assert r.from_date = d1 - 2 and r.is_backfill, format('the marker moved, not reset %s', to_jsonb(r));
  assert punchly_advance(v_org, current_date) is null, 'history caught up clears the marker';
  select from_date, to_date, is_backfill into r from punchly_due();
  assert r.from_date = current_date - 1 and r.to_date = current_date and not r.is_backfill,
         format('the ordinary round is today and yesterday %s', to_jsonb(r));

  -- ===== the wage sheet, and who may run it =====
  perform set_config('request.jwt.claim.sub', uid_acct::text, true); set local role authenticated;
  select present, half_days, leave_days, worked_hours, ot_hours, wage, needs_review as review
    into r from attendance_summary(d1, current_date) where staff_id = v_ramesh;
  assert r.present = 2 and r.half_days = 0 and r.worked_hours = 18 and r.ot_hours = 2 and r.wage = 1200 and r.review = 1,
         format('ramesh sheet %s', to_jsonb(r));
  select present, leave_days, wage into r from attendance_summary(d1, current_date) where staff_id = v_laxmi;
  assert r.present = 0 and r.leave_days = 1 and r.wage = 0, format('laxmi sheet %s', to_jsonb(r));
  select count(*) into n from attendance_register(d1, current_date);
  assert n = 3, format('the accountant sees the register without rights on the staff table, found %s', n);
  -- but the roster is the owner's, because linking rewrites a staff row
  begin
    perform punchly_roster();
    assert false, 'an accountant must not see the Punchly roster';
  exception when others then null; end;

  reset role; perform set_config('request.jwt.claim.sub', '', true);

  -- ===== the plan caps it: Starter has no attendance =====
  perform set_license_plan(v_org, 'starter');
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  begin
    perform attendance_summary(d1, current_date);
    assert false, 'Starter must not reach the wage sheet';
  exception when others then null; end;
  begin
    perform save_attendance(jsonb_build_object('staff_id', v_ramesh, 'work_date', current_date, 'status', 'present'));
    assert false, 'Starter must not be able to write attendance';
  exception when others then null; end;
  -- attendance lives in the Payments module, which Starter does not have at all, so the
  -- rows are hidden rather than merely frozen — nothing is deleted, and Growth brings
  -- them all back untouched
  select count(*) into n from attendance; assert n = 0, format('Starter hides the whole module, found %s', n);

  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform set_license_plan(v_org, 'growth');
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  select count(*) into n from attendance; assert n = 3, format('Growth gives every row back, found %s', n);
  select count(*) into n from attendance_summary(d1, current_date); assert n = 6, format('Growth opens it again, %s staff', n);
  j := license_status();
  assert j->'features' ? 'attendance', format('growth features %s', j->'features');
  assert jsonb_array_length(j->'catalogue') = 14, format('catalogue %s', jsonb_array_length(j->'catalogue'));

  reset role;
  raise notice 'OK: attendance — the key stays server-side, the roster links itself on an exact name and by hand otherwise, punches fold into one row a day with hours, overtime and wages, a late check-out completes yesterday, hand-typed rows survive every sync, GPS only on request, the backfill marker resumes, the accountant runs the sheet without rights on staff, and Starter is capped';
end $$;

rollback;
