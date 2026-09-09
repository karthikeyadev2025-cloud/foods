-- ============================================================
-- DB acceptance test: searching a bill by any detail on it. Rolls back.
--
-- 33 searched number, party and town. Everything below found nothing before 34,
-- and every one of them is a thing somebody actually types: a phone number off
-- the screen, an amount, the item they are chasing, a vehicle, a cheque number,
-- a note. This also runs every branch of the function, which matters because
-- plpgsql does not check the query until it is executed.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid; v_other uuid; v_sup uuid; v_veh uuid;
  v_kaju uuid; v_pak uuid; v_cash uuid; v_chq uuid; v_head uuid;
  v_inv uuid; v_q uuid; v_ch uuid; v_rec uuid; v_pu uuid; v_ret uuid; v_pr uuid; v_pay uuid; v_ord uuid;
  n int;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into receipt_modes (org_id, code, name) values (v_org, 'CASH', 'Cash') returning id into v_cash;
  insert into receipt_modes (org_id, code, name, needs_reference, is_cheque)
    values (v_org, 'CHQ', 'Cheque', true, true) returning id into v_chq;
  insert into expense_heads (org_id, name) values (v_org, 'Diesel') returning id into v_head;
  insert into suppliers (org_id, name) values (v_org, 'SUGAR TRADERS') returning id into v_sup;
  insert into vehicles (org_id, vehicle_number) values (v_org, 'AP07 TZ 1234') returning id into v_veh;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746') returning id into v_cust;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'MASTAN VALI', 'TAKKELLAPADU', '9000000002') returning id into v_other;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '8', 'HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42, 30) returning id into v_pak;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '91', 'KAJU KATLI 250G', v_uom, 10, 1, 300, 220) returning id into v_kaju;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_pak, v_loc, 'opening', current_date, 5000, 30), (v_org, v_kaju, v_loc, 'opening', current_date, 5000, 220);

  -- One of every kind. The KAJU only ever appears on the invoice's lines.
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text,
                       'vehicle_id', v_veh, 'lr_no', 'LR-9931', 'notes', 'left at the temple gate'),
    jsonb_build_array(jsonb_build_object('item_id', v_kaju, 'boxes', 2, 'rate', 300)));
  perform set_invoice_status(v_inv, 'confirmed');
  v_q := save_quotation(
    jsonb_build_object('customer_id', v_other, 'quote_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'boxes', 1, 'rate', 42)));
  v_ch := save_challan(
    jsonb_build_object('customer_id', v_other, 'location_id', v_loc, 'challan_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'boxes', 1)));
  v_ord := save_order(
    jsonb_build_object('kind', 'sale', 'customer_id', v_other, 'order_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'boxes', 3, 'rate', 42)));
  v_rec := save_receipt(
    jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date::text),
    jsonb_build_array(jsonb_build_object('mode_id', v_chq, 'amount', 15000, 'reference', 'CHQ-778812')));
  v_pay := save_payment(jsonb_build_object('payment_date', current_date::text, 'mode_id', v_cash,
                                           'expense_head_id', v_head, 'amount', 2500, 'narration', 'diesel for the Macherla run'));
  v_pu := save_purchase(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'qty', 10, 'uom_id', v_uom, 'rate', 30)));
  v_ret := save_sales_return(
    jsonb_build_object('kind', 'fresh_return', 'customer_id', v_cust, 'location_id', v_loc, 'return_date', current_date::text, 'invoice_id', v_inv),
    jsonb_build_array(jsonb_build_object('item_id', v_kaju, 'boxes', 1, 'rate', 300)));
  v_pr := save_purchase_return(
    jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'return_date', current_date::text, 'purchase_id', v_pu),
    jsonb_build_array(jsonb_build_object('item_id', v_pak, 'qty', 2, 'uom_id', v_uom, 'rate', 30)));

  -- 1. A phone number. The customer rings, their number is on the screen.
  assert exists (select 1 from search_documents('9849686746', 50) where doc_id = v_inv),
    '27.1 a customer mobile number found no bill';

  -- 2. An amount. "the fifteen thousand receipt".
  assert exists (select 1 from search_documents('15000', 50) where doc_id = v_rec),
    '27.2 an amount found no receipt';

  -- 3. An item, which appears nowhere on the document itself — only on a line.
  assert exists (select 1 from search_documents('kaju', 50) where doc_id = v_inv),
    '27.3 an item name did not find the bill it was sold on';
  assert not exists (select 1 from search_documents('kaju', 50) where doc_id = v_q),
    '27.3 an item matched a document that never had it';

  -- 4. An item code on its own.
  assert exists (select 1 from search_documents('91', 50) where doc_id = v_inv),
    '27.4 an item code found nothing';

  -- 5. A vehicle, and an LR number.
  assert exists (select 1 from search_documents('AP07', 50) where doc_id = v_inv), '27.5 vehicle';
  assert exists (select 1 from search_documents('LR-9931', 50) where doc_id = v_inv), '27.5 LR number';

  -- 6. A cheque number, which lives on the receipt's line rather than the receipt.
  assert exists (select 1 from search_documents('778812', 50) where doc_id = v_rec),
    '27.6 a cheque reference found nothing';

  -- 7. A note somebody typed at the time, on a bill and on a payment.
  assert exists (select 1 from search_documents('temple gate', 50) where doc_id = v_inv), '27.7 invoice note';
  assert exists (select 1 from search_documents('diesel', 50) where doc_id = v_pay), '27.7 payment narration';

  -- 8. Words landing in DIFFERENT places: the item on a line, the customer on
  --    the document. This is the case the condition is shaped for.
  assert exists (select 1 from search_documents('kaju srinivas', 50) where doc_id = v_inv),
    '27.8 an item plus a customer found nothing';
  assert not exists (select 1 from search_documents('kaju mastan', 50) where doc_id = v_inv),
    '27.8 the AND stopped narrowing once lines were involved';

  -- 9. Every kind is still reachable — this walks all nine branches, which is
  --    the only way plpgsql checks their SQL at all.
  assert exists (select 1 from search_documents('mysoor', 80) where kind = 'quotation'), '27.9 quotation';
  assert exists (select 1 from search_documents('mysoor', 80) where kind = 'challan'), '27.9 challan';
  assert exists (select 1 from search_documents('mysoor', 80) where kind = 'order'), '27.9 order';
  assert exists (select 1 from search_documents('mysoor', 80) where kind = 'purchase'), '27.9 purchase';
  assert exists (select 1 from search_documents('mysoor', 80) where kind = 'purchase_return'), '27.9 purchase return';
  assert exists (select 1 from search_documents('kaju', 80) where kind = 'return'), '27.9 sales return';
  assert exists (select 1 from search_documents('diesel', 80) where kind = 'payment'), '27.9 payment';

  -- 10. And it still narrows rather than returning the book.
  select count(*) into n from search_documents('srinivas takkellapadu', 80);
  assert n = 0, format('27.10 two customers matched together, got %s', n);

  raise notice 'OK: search by any detail — a phone number, an amount, an item name or code, a vehicle, an LR or cheque number and a typed note all find their bill; words may land on the document or on its lines and still have to all match; all nine kinds run';
end $$;

rollback;
