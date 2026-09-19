-- ============================================================
-- DB acceptance test: the stock report's columns mean what they say. Rolls back.
--
-- Straight from the shop's own screen. 1/- KALAJAM(12): a purchase of 27 jars
-- (2.25 boxes) and a bill for 2 boxes that was then cancelled. The report said
--
--   Opening 0   Purchase 4.25   Sales 2   Closing 2.25
--
-- and the only figure anybody could trust was the closing one. Cancelling a
-- bill puts the goods back, which is a positive movement, and the column headed
-- "Purchase" was adding up every positive movement — so the 2 boxes that came
-- back were reported as bought.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_loc uuid; v_cust uuid; v_sup uuid; v_sec uuid;
  v_kalajam uuid; v_inv uuid; r record;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into sections (org_id, name, sort_order) values (v_org,'OUTER',1) returning id into v_sec;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into suppliers (org_id, name) values (v_org,'SUGAR TRADERS') returning id into v_sup;
  insert into items (org_id, item_code, name, section_id, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'2760','1/- KALAJAM(12)', v_sec, v_jar, 12, 1, 15, 10) returning id into v_kalajam;

  -- 27 jars in. Two and a quarter boxes, which is what really arrived.
  perform save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'qty', 27, 'uom_id', v_jar, 'rate', 10)));

  select * into r from closing_stock_report(v_org, current_date, v_loc) where item_id = v_kalajam;
  assert r.purchase = 2.25, format('43.1 purchase reads %s, not the 2.25 that came in', r.purchase);
  assert r.closing = 2.25, format('43.1 closing %s', r.closing);
  assert r.sales = 0 and r.other = 0, format('43.1 sales %s, other %s before anything was sold', r.sales, r.other);

  -- A bill for 2 boxes, confirmed: it goes out.
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 2, 'rate', 15)));
  perform set_invoice_status(v_inv, 'confirmed');

  select * into r from closing_stock_report(v_org, current_date, v_loc) where item_id = v_kalajam;
  assert r.purchase = 2.25, format('43.2 a sale changed the purchase column to %s', r.purchase);
  assert r.sales = 2, format('43.2 sales %s', r.sales);
  assert r.closing = 0.25, format('43.2 closing %s', r.closing);

  -- ============================================================
  -- THE ONE THAT WAS WRONG. Cancel the bill: the goods come back.
  -- ============================================================
  perform set_invoice_status(v_inv, 'cancelled');
  select * into r from closing_stock_report(v_org, current_date, v_loc) where item_id = v_kalajam;

  assert r.purchase = 2.25,
    format('43.3 the cancelled bill was counted as a purchase: %s (this is the 4.25 from the shop)', r.purchase);
  assert r.purchase <> 4.25, '43.3 the original fault is back';

  --    A bill raised and cancelled on the same day nets to nothing. It is not
  --    two boxes sold and two boxes bought; it is a bill that never happened.
  assert r.sales = 0, format('43.3 sales still shows %s after the bill was cancelled', r.sales);
  assert r.other = 0, format('43.3 the return leaked into other: %s', r.other);
  assert r.closing = 2.25, format('43.3 closing %s', r.closing);

  -- ============================================================
  -- THE ROW STILL ADDS UP LEFT TO RIGHT, which is what a shopkeeper checks.
  -- ============================================================
  --    A godown transfer out is neither a purchase nor a sale, so it belongs in
  --    "other" — and the row must still reconcile with it there.
  insert into stock_locations (org_id, name) values (v_org,'Shop') returning id into v_cust;
  perform save_stock_transfer(
    jsonb_build_object('from_location', v_loc, 'to_location', v_cust, 'txn_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_kalajam, 'boxes', 1)));

  select * into r from closing_stock_report(v_org, current_date, v_loc) where item_id = v_kalajam;
  assert r.other = -1, format('43.4 a transfer out reads %s in other', r.other);
  assert r.purchase = 2.25 and r.sales = 0, format('43.4 a transfer moved purchase to %s / sales to %s', r.purchase, r.sales);
  assert r.closing = 1.25, format('43.4 closing %s', r.closing);
  assert r.opening + r.purchase + r.production - r.sales + r.other = r.closing,
    format('43.4 the row does not add up: %s + %s + %s - %s + %s <> %s',
           r.opening, r.purchase, r.production, r.sales, r.other, r.closing);

  raise notice 'OK: the stock report — Purchase means goods bought and nothing else, Sales means goods sold, a bill cancelled the same day nets to nothing in both rather than being reported as two boxes bought and two sold, everything else nets into one signed Other column, and opening + purchase + production - sales + other still equals closing';
end $$;

rollback;
