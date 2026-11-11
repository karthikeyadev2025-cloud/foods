-- ============================================================
-- DB acceptance test: vehicle-wise and supplier-wise reports.
--
-- "The same vehicle may be assigned to multiple customers… maintain all
-- related transactions under that particular vehicle." The vehicle number is
-- typed by hand, so the test types it the way three different people would.
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
  v_org uuid; v_jar uuid; v_loc uuid; v_item uuid; v_sup uuid; v_sup2 uuid;
  c1 uuid; c2 uuid; c3 uuid; v_inv uuid; v_pur uuid; v_mode uuid;
  r record; n int; q numeric;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');

  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'8','MYSOOR PAK', v_jar, 10, 1, 10, 6) returning id into v_item;
  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base)
    values (v_org,v_item,v_loc,'opening',current_date - 30, 100000);
  insert into customers (org_id,name,town) values (v_org,'RAVI STORES','MACHERLA') returning id into c1;
  insert into customers (org_id,name,town) values (v_org,'SRI LAKSHMI','TENALI')   returning id into c2;
  insert into customers (org_id,name,town) values (v_org,'BALAJI TRADERS','GUNTUR') returning id into c3;

  -- ===== 55.1 one van, three customers, three spellings of its number =====
  v_inv := save_invoice(jsonb_build_object('customer_id', c1, 'invoice_date', (current_date-2)::text, 'location_id', v_loc,
                                           'transport_name','RAMESH','lr_no','AP16 TC 1234'),
                        jsonb_build_array(jsonb_build_object('item_id',v_item,'boxes',5,'rate',10)));
  perform set_invoice_status(v_inv,'confirmed');
  v_inv := save_invoice(jsonb_build_object('customer_id', c2, 'invoice_date', (current_date-1)::text, 'location_id', v_loc,
                                           'transport_name','RAMESH','lr_no','ap16tc1234'),
                        jsonb_build_array(jsonb_build_object('item_id',v_item,'boxes',3,'rate',10)));
  perform set_invoice_status(v_inv,'confirmed');
  v_inv := save_invoice(jsonb_build_object('customer_id', c3, 'invoice_date', current_date::text, 'location_id', v_loc,
                                           'transport_name','SURESH','lr_no','AP-16-TC-1234'),
                        jsonb_build_array(jsonb_build_object('item_id',v_item,'boxes',2,'rate',10)));
  perform set_invoice_status(v_inv,'confirmed');

  -- a different van, so the grouping has something to get wrong
  v_inv := save_invoice(jsonb_build_object('customer_id', c1, 'invoice_date', current_date::text, 'location_id', v_loc,
                                           'transport_name','KUMAR','lr_no','AP07 AB 9999'),
                        jsonb_build_array(jsonb_build_object('item_id',v_item,'boxes',4,'rate',10)));
  perform set_invoice_status(v_inv,'confirmed');

  select count(*) into n from vehicle_summary(v_org, current_date-7, current_date);
  assert n = 2, format('55.1 three spellings of one van plus another is 2 vehicles, got %s', n);

  select * into r from vehicle_summary(v_org, current_date-7, current_date) where vehicle_key = 'AP16TC1234';
  assert r.trips = 3, format('55.1 the van made 3 trips, shows %s', r.trips);
  assert r.customers = 3, format('55.1 it served 3 customers, shows %s', r.customers);
  assert r.boxes = 10, format('55.1 it carried 10 boxes, shows %s', r.boxes);
  assert r.amount = (5+3+2) * 10 * 10, format('55.1 it carried %s worth', r.amount);
  assert r.drivers like '%RAMESH%' and r.drivers like '%SURESH%', format('55.1 both drivers: %s', r.drivers);
  assert r.first_run = current_date - 2 and r.last_run = current_date, '55.1 the dates it ran';

  -- ===== 55.2 the detail behind one vehicle =====
  select count(*) into n from vehicle_report(v_org, current_date-7, current_date, 'AP 16 TC 1234');
  assert n = 3, format('55.2 asking for the van by a fourth spelling should still find 3 bills, got %s', n);
  select count(distinct customer) into n from vehicle_report(v_org, current_date-7, current_date, 'ap16tc1234');
  assert n = 3, '55.2 all three customers are under the one vehicle';

  -- ===== 55.3 a bill with no vehicle is not a vehicle =====
  v_inv := save_invoice(jsonb_build_object('customer_id', c1, 'invoice_date', current_date::text, 'location_id', v_loc),
                        jsonb_build_array(jsonb_build_object('item_id',v_item,'boxes',1,'rate',10)));
  perform set_invoice_status(v_inv,'confirmed');
  select count(*) into n from vehicle_summary(v_org, current_date-7, current_date);
  assert n = 2, format('55.3 a counter sale with no van must not invent one, got %s vehicles', n);

  -- ===== 55.4 a cancelled bill leaves the vehicle's figures =====
  select invoice_id into v_inv from vehicle_report(v_org, current_date-7, current_date, 'ap16tc1234') limit 1;
  perform set_invoice_status(v_inv, 'cancelled');
  select * into r from vehicle_summary(v_org, current_date-7, current_date) where vehicle_key = 'AP16TC1234';
  assert r.trips = 2, format('55.4 a cancelled bill should drop out, trips %s', r.trips);

  -- ===== 55.5 supplier-wise =====
  insert into suppliers (org_id, name, town, mobile1, opening_balance)
    values (v_org,'SUGAR TRADERS','GUNTUR','9849000001', 5000) returning id into v_sup;
  insert into suppliers (org_id, name, town, opening_balance)
    values (v_org,'OIL MILLS','TENALI', 0) returning id into v_sup2;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order)
    values (v_org,'CASH','Cash', true, false, 1) returning id into v_mode;

  -- before the period: 2,000 bought
  v_pur := save_purchase(jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', (current_date-20)::text),
                         jsonb_build_array(jsonb_build_object('item_id',v_item,'boxes',20,'rate',10)));
  -- inside it: 3,000 bought and 1,200 paid
  v_pur := save_purchase(jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', (current_date-3)::text),
                         jsonb_build_array(jsonb_build_object('item_id',v_item,'boxes',30,'rate',10)));
  perform save_payment(jsonb_build_object('supplier_id', v_sup, 'amount', 1200, 'mode_id', v_mode, 'payment_date', (current_date-1)::text));

  select * into r from supplier_report(v_org, current_date-7, current_date) where supplier_id = v_sup;
  assert r.opening  = 5000 + 2000, format('55.5 opening should be 7000, is %s', r.opening);
  assert r.purchases = 3000,       format('55.5 bought 3000 in the period, shows %s', r.purchases);
  assert r.payments  = 1200,       format('55.5 paid 1200, shows %s', r.payments);
  assert r.closing   = 7000 + 3000 - 1200, format('55.5 closing should be 8800, is %s', r.closing);
  assert r.bills = 1, format('55.5 one bill in the period, shows %s', r.bills);
  assert r.town = 'GUNTUR' and r.mobile = '9849000001', '55.5 the supplier''s own details';

  -- a supplier with nothing is still listed, at zero, so nobody wonders
  select * into r from supplier_report(v_org, current_date-7, current_date) where supplier_id = v_sup2;
  assert r.closing = 0 and r.purchases = 0, '55.5 an idle supplier reads zero, not nothing';

  -- ===== 55.6 the ledger behind one supplier, and it ties to the report =====
  select count(*) into n from supplier_ledger(v_sup);
  assert n = 1 + 2 + 1, format('55.6 opening + two bills + one payment = 4 rows, got %s', n);
  -- the LAST row, so nulls last: the Opening row carries no date and would
  -- otherwise sort to the top of a descending order and be read as the close
  select balance into q from (select balance, entry_date, doc_no from supplier_ledger(v_sup)) x
   order by entry_date desc nulls last, doc_no desc limit 1;
  assert q = 8800, format('55.6 the ledger must close where the report does: %s', q);

  -- what the shop owes shows as a credit; what it pays, a debit
  select debit, credit into r from supplier_ledger(v_sup) where doc = 'Payment';
  assert r.debit = 1200 and r.credit = 0, '55.6 a payment reduces what is owed';

  raise notice 'OK: a van is one van however its number is typed — AP16 TC 1234, ap16tc1234 and AP-16-TC-1234 are the same vehicle, with every customer it served under it, its drivers, boxes, value and the days it ran; a counter sale with no van invents none and a cancelled bill drops out; suppliers get opening, purchases, returns, payments and closing for a period, an idle supplier reads zero rather than vanishing, and the ledger behind one closes exactly where the report says';
end $$;

rollback;
