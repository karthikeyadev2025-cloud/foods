-- ============================================================
-- DB acceptance test: a counter that resets needs a date to reset into.
-- Rolls back.
--
-- The shop's invoice series was set to reset EVERY DAY with no prefix at all.
-- That cannot work: tomorrow's 01 is last week's 01. This test holds the two
-- halves of the answer — a date in the number makes the reset real, and a reset
-- without one is named rather than left to surface as a 23505 at the till.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_item uuid;
  v_inv uuid; v_no text; v_msg text; n bigint;
  y date := current_date - 1;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42) returning id into v_item;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_item, v_loc, 'opening', current_date, 100000, 30);

  -- 1. The tokens are filled in from the date, and {YYYY} is not eaten by {YY}.
  assert doc_no_stamp('{YYYY}-{YY}-{MM}-{DD}', date '2026-09-16') = '2026-26-09-16',
    format('38.1 stamped as %s', doc_no_stamp('{YYYY}-{YY}-{MM}-{DD}', date '2026-09-16'));
  assert doc_no_stamp(null) = '', '38.1 a series with no prefix stamped to null';

  -- 2. THE SHOP'S SETTING. Daily reset, no prefix — named, not left to the till.
  v_msg := numbering_warning('daily', '', '');
  assert v_msg is not null, '38.2 a daily reset with no date in the number was called fine';
  assert v_msg like '%{YYYY}{MM}{DD}%', format('38.2 does not say what to put in: %s', v_msg);
  assert v_msg like '%every day%', format('38.2 does not say how often: %s', v_msg);

  --    Monthly needs the year too, or January 2027 lands on January 2026.
  assert numbering_warning('monthly', '{MM}/', '') is not null,
    '38.2 a monthly reset with only the month in it was called fine';
  assert numbering_warning('monthly', '{YY}{MM}/', '') is null,
    '38.2 year and month together were still refused';
  assert numbering_warning('yearly',  '{YYYY}-', '') is null, '38.2 a dated yearly series was refused';
  assert numbering_warning('daily',   '{YY}{MM}{DD}/', '') is null, '38.2 a dated daily series was refused';
  assert numbering_warning('never',   '', '') is null, '38.2 a series that never resets was warned about';

  -- 3. A DATED SERIES RESTARTS INTO NUMBERS NOBODY HAS HAD. Yesterday's 01 is
  --    not today's 01, so the counter going back to 1 is safe.
  -- Upserted, not updated: a brand new organisation has no invoice series until
  -- the first bill makes one, so an UPDATE here matches nothing and the test
  -- silently measures the default series instead of the dated one.
  insert into number_series (org_id, doc_type, prefix, width, next_number, reset_period)
       values (v_org, 'invoice', '{YY}{MM}{DD}/', 2, 1, 'daily')
  on conflict (org_id, doc_type) do update
          set prefix = excluded.prefix, width = excluded.width,
              next_number = excluded.next_number, reset_period = excluded.reset_period;

  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  v_no := (select invoice_no from invoices where id = v_inv);
  assert v_no = to_char(current_date, 'YYMMDD') || '/01', format('38.3 first bill of the day is %s', v_no);

  --    Backdate it to yesterday, exactly as the calendar would have, and put the
  --    counter back to 1 the way the daily reset does. Before this file that
  --    would hand back a number already on a bill.
  update invoices set invoice_no = to_char(y, 'YYMMDD') || '/01' where id = v_inv;
  update number_series set next_number = 1 where org_id = v_org and doc_type = 'invoice';

  v_no := next_doc_no(v_org, 'invoice');
  assert v_no = to_char(current_date, 'YYMMDD') || '/01',
    format('38.4 today started at %s instead of 01 — yesterday blocked it', v_no);

  -- 4. Within the same day it still refuses to repeat itself.
  update number_series set next_number = 1 where org_id = v_org and doc_type = 'invoice';
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 42)));
  assert (select invoice_no from invoices where id = v_inv) = to_char(current_date, 'YYMMDD') || '/01',
    '38.5 the first free number of the day was skipped';
  update number_series set next_number = 1 where org_id = v_org and doc_type = 'invoice';
  assert next_doc_no(v_org, 'invoice') = to_char(current_date, 'YYMMDD') || '/02',
    '38.5 a number already on today''s bill was handed out again';

  -- 5. RESYNC READS THE RUNNING NUMBER, NOT EVERY DIGIT. A prefix of '{YYYY}-'
  --    is all digits once it is filled in; stripping non-digits read 2026-0007
  --    as twenty-six million and threw the counter into orbit.
  update number_series
     set prefix = '{YYYY}-', width = 4, next_number = 1, reset_period = 'yearly'
   where org_id = v_org and doc_type = 'invoice';
  update invoices set invoice_no = to_char(current_date, 'YYYY') || '-0007' where id = v_inv;

  select counter_now into n from resync_doc_numbers(v_org) where doc_type = 'invoice';
  assert n = 8, format('38.6 the counter was moved to %s, not 8', n);

  --    And yesterday's differently-dated bills are not this period's business.
  update number_series
     set prefix = '{YY}{MM}{DD}/', width = 2, next_number = 1, reset_period = 'daily'
   where org_id = v_org and doc_type = 'invoice';
  update invoices set invoice_no = to_char(y, 'YYMMDD') || '/09' where id = v_inv;
  update invoices set invoice_no = to_char(y, 'YYMMDD') || '/08'
   where org_id = v_org and id <> v_inv;

  select counter_now, action into n, v_msg from resync_doc_numbers(v_org) where doc_type = 'invoice';
  assert n = 1, format('38.7 yesterday''s bills dragged today''s counter to %s', n);
  assert v_msg = 'nothing numbered yet', format('38.7 said "%s" about a day with no bills on it', v_msg);

  -- 6. EVERY SERIES IS REPORTED, MOVED OR NOT. "No rows" used to mean three
  --    different things — all well, wrong organisation, or no numbering at all
  --    — and there was no way to tell which. Now it means only the last.
  select count(*) into n from resync_doc_numbers(v_org);
  assert n = (select count(*) from number_series where org_id = v_org),
    format('38.8 reported %s series out of %s', n, (select count(*) from number_series where org_id = v_org));

  --    And the report carries the warning, so the setting that caused all this
  --    is named where somebody repairing the numbering will actually see it.
  update number_series set prefix = '' where org_id = v_org and doc_type = 'invoice';
  assert exists (select 1 from resync_doc_numbers(v_org)
                  where doc_type = 'invoice' and warning like '%every day%'),
    '38.8 the report does not carry the warning for a reset with no date in it';

  -- 7. An id that is not an organisation says so, and says how to find the real
  --    one. The old hint was "select id from orgs limit 1", which on a database
  --    with a second organisation quietly repairs the wrong one.
  begin
    perform resync_doc_numbers(gen_random_uuid());
    raise exception '38.9 renumbered an organisation that does not exist';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%No organisation with that id%', format('38.9 wrong reason: %s', v_msg);
    assert v_msg like '%select id, name from orgs%', format('38.9 does not show the way: %s', v_msg);
  end;

  raise notice 'OK: dated numbering — {YYYY} {YY} {MM} {DD} go into the number itself so a daily or yearly reset restarts into numbers nobody has had, a reset with no date in it is named in words, resync reads the running number rather than every digit and leaves other periods alone, and it now reports every series instead of only the ones it moved';
end $$;

rollback;
