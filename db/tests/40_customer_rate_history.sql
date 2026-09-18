-- ============================================================
-- DB acceptance test: what did we charge this customer last time. Rolls back.
--
-- The question at the counter is not "what does the price list say" — that is
-- already answered — but "what did HE pay". A regular on 40 while the list says
-- 42 is the whole reason this exists, so the test bills the same product at
-- three different rates over three days and checks the newest one comes back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_other uuid;
  v_pak uuid; v_laddu uuid; v_inv uuid; v_old uuid;
  uid_owner uuid := gen_random_uuid();
  r record; n bigint; v_rate numeric;

begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into customers (org_id, name) values (v_org,'K. RAMANA') returning id into v_other;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42) returning id into v_pak;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'9','5/- BOONDI LADDU(12) 48', v_uom, 48, 12, 60) returning id into v_laddu;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_pak, v_loc, 'opening', current_date, 100000, 30),
           (v_org, v_laddu, v_loc, 'opening', current_date, 100000, 40);

  -- 1. NOTHING YET. A customer who has never bought says nothing rather than
  --    inventing a rate — the biller falls back to the price list.
  select count(*) into n from customer_last_rates(v_cust);
  assert n = 0, format('40.1 a brand new customer already had %s rates', n);
  select count(*) into n from customer_recent_bills(v_cust);
  assert n = 0, format('40.1 a brand new customer already had %s bills', n);

  -- 2. THE RATE THAT COMES BACK IS THE NEWEST ONE, NOT THE HIGHEST, THE LOWEST
  --    OR THE FIRST. Three days, three different rates on the same product.
  v_old := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', (current_date - 9)::text),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'boxes', 2, 'rate', 44)));
  perform set_invoice_status(v_old, 'confirmed');

  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', (current_date - 2)::text),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'boxes', 3, 'rate', 40),
                      jsonb_build_object('item_id', v_laddu, 'boxes', 1, 'rate', 58)));
  perform set_invoice_status(v_inv, 'confirmed');

  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', (current_date - 5)::text),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'boxes', 1, 'rate', 41)));
  perform set_invoice_status(v_inv, 'confirmed');

  select * into r from customer_last_rates(v_cust) where item_id = v_pak;
  assert r.rate = 40, format('40.2 came back with %s, not the 40 he paid two days ago', r.rate);
  assert r.invoice_date = current_date - 2, format('40.2 dated %s', r.invoice_date);
  assert r.boxes = 3, format('40.2 boxes %s', r.boxes);
  assert r.times_billed = 3, format('40.2 counted %s bills for that product', r.times_billed);
  assert r.item_code = '8' and r.item_name like 'HT. MYSOOR%', '40.2 the product is not named';

  --    And the other product on that bill is remembered separately.
  select rate into v_rate from customer_last_rates(v_cust) where item_id = v_laddu;
  assert v_rate = 58, format('40.3 the laddu came back at %s, not 58', v_rate);

  -- 3. ONE ROW PER PRODUCT, however many times it has been billed.
  select count(*) into n from customer_last_rates(v_cust);
  assert n = 2, format('40.4 expected one row each for two products, got %s', n);

  -- 4. ANOTHER CUSTOMER'S RATES ARE NOT HIS. This is the one that would lose
  --    the shop money quietly: quoting the wholesale regular's price to a
  --    walk-in because the product matched.
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_other, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'boxes', 1, 'rate', 46)));
  perform set_invoice_status(v_inv, 'confirmed');
  select rate into v_rate from customer_last_rates(v_cust) where item_id = v_pak;
  assert v_rate = 40, format('40.5 another customer''s %s leaked onto this one', v_rate);
  select rate into v_rate from customer_last_rates(v_other) where item_id = v_pak;
  assert v_rate = 46, format('40.5 the other customer got %s', v_rate);

  -- 5. A CANCELLED BILL IS NOT A PRICE ANYBODY AGREED TO. Cancel the newest and
  --    the rate falls back to the one before it, rather than standing on a bill
  --    that was withdrawn.
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'boxes', 1, 'rate', 35)));
  perform set_invoice_status(v_inv, 'confirmed');
  select rate into v_rate from customer_last_rates(v_cust) where item_id = v_pak;
  assert v_rate = 35, format('40.6 the newest bill did not take effect: %s', v_rate);

  perform set_invoice_status(v_inv, 'cancelled');
  select rate into v_rate from customer_last_rates(v_cust) where item_id = v_pak;
  assert v_rate = 40, format('40.6 a cancelled bill is still being quoted at %s', v_rate);

  -- 6. THE BILL LIST. Newest first, with its own totals, and the cancelled one
  --    still visible — a biller asking what happened to it deserves an answer.
  select count(*) into n from customer_recent_bills(v_cust);
  assert n = 4, format('40.7 expected four bills, got %s', n);
  select * into r from customer_recent_bills(v_cust) limit 1;
  assert r.status = 'cancelled' and r.invoice_date = current_date,
    format('40.7 the newest is %s of %s', r.status, r.invoice_date);
  assert exists (select 1 from customer_recent_bills(v_cust) where status = 'cancelled'),
    '40.7 the cancelled bill vanished from the list instead of being marked';

  --    The limit is honoured and cannot be talked into returning everything.
  select count(*) into n from customer_recent_bills(v_cust, 2);
  assert n = 2, format('40.8 asked for 2, got %s', n);
  select count(*) into n from customer_recent_bills(v_cust, 0);
  assert n = 1, format('40.8 a limit of nought returned %s', n);

  -- 7. OPENING ONE OF THEM shows what was on it, at the rates it was billed at.
  select count(*) into n from invoice_lines_for_reading(v_old);
  assert n = 1, format('40.9 the old bill had %s lines', n);
  select rate into v_rate from invoice_lines_for_reading(v_old) limit 1;
  assert v_rate = 44, format('40.9 the old bill reads at %s, not the 44 it was billed at', v_rate);

  -- 8. ANOTHER SHOP'S BILLS ARE INVISIBLE. These read through SECURITY DEFINER,
  --    so the org check inside them is the only thing there is — if it were ever
  --    dropped, one shop would be reading another's prices with no error.
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  select count(*) into n from customer_last_rates(v_cust);
  assert n = 0, format('40.10 a stranger read %s of this shop''s rates', n);
  select count(*) into n from customer_recent_bills(v_cust);
  assert n = 0, format('40.10 a stranger read %s of this shop''s bills', n);
  select count(*) into n from invoice_lines_for_reading(v_old);
  assert n = 0, format('40.10 a stranger read %s lines off this shop''s bill', n);

  raise notice 'OK: customer rate history — the last rate a customer actually paid comes back per product, newest not highest, one row each however often it was billed, another customer''s rates never leak across, a cancelled bill is never quoted from but still shows on his bill list, the limit holds, a bill opens at the rates it was billed at, and another shop sees none of it';
end $$;

rollback;
