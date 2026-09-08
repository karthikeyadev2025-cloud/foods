-- ============================================================
-- DB acceptance test: T8 documents & pricing. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_route uuid; v_cust uuid; v_cust2 uuid; v_sup uuid; v_sec uuid; v_a uuid; v_b uuid;
  pl_w uuid; pl_r uuid; v_q uuid; v_inv uuid; v_ord uuid; v_po uuid; v_doc uuid; v_ch uuid; v_ch2 uuid; v_pr uuid; v_io uuid; v_secret text;
  r record; n int; q numeric; j jsonb;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into routes (org_id, name) values (v_org, 'Macherla line') returning id into v_route;
  insert into sections (org_id, code, name, sort_order) values (v_org, 'S-1', 'CHINNA MASTRY', 1) returning id into v_sec;
  insert into customers (org_id, name, town, mobile1, route_id) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746', v_route) returning id into v_cust;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'RETAIL SHOP', 'GUNTUR', '9000000002') returning id into v_cust2;
  insert into suppliers (org_id, name) values (v_org, 'SUGAR TRADERS') returning id into v_sup;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate, section_id)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, 32, 12, 42, 30, v_sec) returning id into v_a;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate, section_id)
    values (v_org, '12', '5/- BOONDI LADDU (12) 48', v_uom, v_pack, 48, 12, 5, 3, v_sec) returning id into v_b;

  -- ===== price lists =====
  insert into price_lists (org_id, name) values (v_org, 'Wholesale') returning id into pl_w;
  insert into price_lists (org_id, name, is_default) values (v_org, 'Retail', true) returning id into pl_r;
  perform set_price_list_rate(pl_w, v_a, 40);
  perform set_price_list_rate(pl_r, v_a, 45);
  update customers set price_list_id = pl_w where id = v_cust;
  assert effective_unit_rate(v_a, v_cust) = 40, 'customer list wins over master';
  assert effective_unit_rate(v_a, v_cust2) = 45, 'default list for everyone else';
  assert effective_unit_rate(v_b, v_cust2) = 5, 'not on any list → master rate';
  insert into item_price_overrides (org_id, item_id, customer_id, unit_rate) values (v_org, v_a, v_cust, 39);
  assert effective_unit_rate(v_a, v_cust) = 39, 'a per-customer override still beats the list';
  delete from item_price_overrides where customer_id = v_cust;
  n := bulk_update_price_list(pl_w, 'pct', 10); assert n = 1;
  assert effective_unit_rate(v_a, v_cust) = 44, format('after +10%%: %s', effective_unit_rate(v_a, v_cust));
  n := bulk_update_price_list(pl_w, 'copy_master', 0, null); assert n = 2, format('copy master fills both items: %s', n);
  assert effective_unit_rate(v_a, v_cust) = 42 and effective_unit_rate(v_b, v_cust) = 5, 'copied from master';
  n := bulk_update_price_list(pl_w, 'copy_list', 0, null, pl_r); assert n = 1;
  assert effective_unit_rate(v_a, v_cust) = 45, 'copied from retail';
  perform set_price_list_rate(pl_w, v_a, 44);
  select count(*) into n from price_list_rates(pl_w) where list_rate is not null; assert n = 2;
  update price_lists set valid_to = current_date - 1 where id = pl_w;
  assert effective_unit_rate(v_a, v_cust) = 45, 'expired list falls through to the default';
  update price_lists set valid_to = null where id = pl_w;
  n := assign_price_list(pl_r, v_route); assert n = 1, 'assign by route';
  select price_list_id into r from customers where id = v_cust; assert r.price_list_id = pl_r;
  update customers set price_list_id = pl_w where id = v_cust;
  insert into price_lists (org_id, name, is_default) values (v_org, 'Festival', true);
  select count(*) into n from price_lists where org_id = v_org and is_default; assert n = 1, 'one default at a time';
  update price_lists set is_default = true where id = pl_r;
  select item_count, customer_count into r from v_price_lists where id = pl_w; assert r.item_count = 2 and r.customer_count = 1;

  -- ===== discount schemes =====
  insert into discount_schemes (org_id, name, item_id, min_boxes, discount_pct) values (v_org, '5% on 10 boxes of 8', v_a, 10, 5);
  insert into discount_schemes (org_id, name, section_id, min_boxes, free_boxes) values (v_org, '1 free on 10 (section)', v_sec, 10, 1);
  select name into r from discount_for(v_org, v_a, 10); assert r.name = '5% on 10 boxes of 8', 'item scheme beats section scheme';
  select name into r from discount_for(v_org, v_b, 10); assert r.name = '1 free on 10 (section)';
  select count(*) into n from discount_for(v_org, v_a, 9); assert n = 0, 'below minimum';

  -- ===== quotation → invoice =====
  v_q := save_quotation(jsonb_build_object('customer_id', v_cust, 'quote_date', current_date, 'valid_till', current_date + 7, 'transport_name', 'KPN', 'freight', 100),
           jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 2), jsonb_build_object('item_id', v_b, 'boxes', 10, 'rate', 5)));
  select * into r from v_quotation_list where id = v_q;
  -- A: 2 × 32 × 44 (wholesale list) = 2816; B: 10 × 48 × 5 = 2400
  assert r.subtotal = 5216 and r.total = 5316 and r.line_count = 2 and r.total_boxes = 12 and r.quote_no is not null and not r.is_expired, format('quotation %s', to_jsonb(r));
  select rate into q from v_quotation_lines where quotation_id = v_q and item_id = v_a; assert q = 44, 'rate defaulted from the customer''s list';
  v_q := save_quotation(jsonb_build_object('id', v_q, 'customer_id', v_cust, 'quote_date', current_date, 'freight', 100),
           jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 2, 'rate', 44), jsonb_build_object('item_id', v_b, 'boxes', 10, 'rate', 5)));
  select count(*) into n from quotation_items where quotation_id = v_q; assert n = 2, 'edit replaces lines';
  v_inv := convert_quotation(v_q, v_loc);
  select state::text, invoice_id into r from quotations where id = v_q; assert r.state = 'converted' and r.invoice_id = v_inv;
  select subtotal, total, status::text into r from invoices where id = v_inv; assert r.subtotal = 5216 and r.total = 5316 and r.status = 'draft', format('invoice from quotation: %s', to_jsonb(r));
  select count(*) into n from invoice_items where invoice_id = v_inv; assert n = 2;
  begin
    perform save_quotation(jsonb_build_object('id', v_q, 'customer_id', v_cust), jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 1))); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Quotation is converted%', sqlerrm; end;
  begin
    perform convert_quotation(v_q, v_loc); raise exception 'should fail';
  exception when others then assert sqlerrm like '% is converted', sqlerrm; end;

  -- ===== schemes on the draft invoice =====
  j := apply_discount_schemes(v_inv);
  assert (j->>'discount')::numeric = 0 and jsonb_array_length(j->'free_lines') = 1, format('schemes: %s', j);
  select count(*) into n from invoice_items where invoice_id = v_inv; assert n = 3, 'a free line was added';
  select boxes, rate, amount into r from invoice_items where invoice_id = v_inv and rate = 0; assert r.boxes = 1 and r.amount = 0;
  update discount_schemes set min_boxes = 2 where item_id = v_a;
  j := apply_discount_schemes(v_inv);
  assert (j->>'discount')::numeric = 140.80, format('5%% of 2816: %s', j);
  select count(*) into n from invoice_items where invoice_id = v_inv; assert n = 3, 'free line not duplicated on re-run';
  select discount, total into r from invoices where id = v_inv; assert r.discount = 140.80 and r.total = 5216 - 140.80 + 100, format('invoice after scheme %s', to_jsonb(r));

  -- ===== sale order, partial fulfilment =====
  v_ord := save_order(jsonb_build_object('kind', 'sale', 'customer_id', v_cust, 'due_date', current_date + 2),
             jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 5), jsonb_build_object('item_id', v_b, 'boxes', 2)));
  select * into r from v_order_list where id = v_ord;
  assert r.state = 'open' and r.total = 5 * 32 * 44 + 2 * 48 * 5 and r.total_boxes = 7 and r.delivered_boxes = 0 and r.order_no is not null, format('order %s', to_jsonb(r));
  begin
    perform fulfil_order(v_ord, jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 6)), jsonb_build_object('location_id', v_loc)); raise exception 'should fail';
  exception when others then assert sqlerrm like '%only 5.000 pending%', sqlerrm; end;
  v_doc := fulfil_order(v_ord, jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 3)), jsonb_build_object('location_id', v_loc));
  select state::text, delivered_boxes, fulfilments into r from v_order_list where id = v_ord; assert r.state = 'partial' and r.delivered_boxes = 3 and r.fulfilments = 1, format('partial %s', to_jsonb(r));
  select pending_boxes into q from v_order_lines where order_id = v_ord and item_id = v_a; assert q = 2;
  select total, status::text into r from invoices where id = v_doc; assert r.total = 3 * 32 * 44 and r.status = 'draft', 'draft invoice for the delivered part';
  begin
    perform save_order(jsonb_build_object('id', v_ord, 'kind', 'sale', 'customer_id', v_cust), jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 1))); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Order % is partial%', sqlerrm; end;
  v_doc := fulfil_order(v_ord, null, jsonb_build_object('location_id', v_loc));
  select state::text, delivered_boxes, fulfilments into r from v_order_list where id = v_ord; assert r.state = 'completed' and r.delivered_boxes = 7 and r.fulfilments = 2, format('completed %s', to_jsonb(r));
  select total into q from invoices where id = v_doc; assert q = 2 * 32 * 44 + 2 * 48 * 5, format('rest of the order %s', q);
  begin
    perform fulfil_order(v_ord, null, jsonb_build_object('location_id', v_loc)); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Order % is completed', sqlerrm; end;
  select count(*) into n from v_order_fulfilments where order_id = v_ord and doc_no is not null; assert n = 2;

  -- ===== purchase order → purchase bill =====
  v_po := save_order(jsonb_build_object('kind', 'purchase', 'supplier_id', v_sup), jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 10)));
  select rate, amount into r from v_order_lines where order_id = v_po; assert r.rate = 30 and r.amount = 10 * 32 * 30, 'purchase rate from the master';
  v_doc := fulfil_order(v_po, null, jsonb_build_object('location_id', v_loc, 'bill_no', 'B-1'));
  select total, bill_no into r from purchases where id = v_doc; assert r.total = 9600 and r.bill_no = 'B-1', format('purchase from order %s', to_jsonb(r));
  select qty, qty_base into r from purchase_items where purchase_id = v_doc; assert r.qty = 320 and r.qty_base = 320;
  select state::text into r from orders where id = v_po; assert r.state = 'completed';
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_a; assert q = 320, format('stock after purchase %s', q);

  -- ===== WhatsApp order → sale order =====
  j := save_messaging_settings(jsonb_build_object('api_key', 'k', 'is_enabled', true));
  v_secret := j->>'webhook_secret';
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  j := receive_inbound_order(jsonb_build_object('secret', v_secret, 'from', '9849686746', 'text', '4 box 8', 'parsed_items', jsonb_build_array(jsonb_build_object('item_code', '8', 'qty', 4))));
  v_io := (j->>'id')::uuid;
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  v_ord := convert_inbound_to_order(v_io, jsonb_build_object('customer_id', v_cust), jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 4)));
  select status::text, order_no into r from v_inbound_orders where id = v_io; assert r.status = 'confirmed' and r.order_no is not null, format('inbound → order %s', to_jsonb(r));
  select source_inbound_id into r from orders where id = v_ord; assert r.source_inbound_id = v_io;
  perform cancel_order(v_ord);
  select state::text into r from orders where id = v_ord; assert r.state = 'cancelled';

  -- ===== delivery challan: goods out now, bill later =====
  v_ch := save_challan(jsonb_build_object('customer_id', v_cust, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 1)));
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_a; assert q = 320 - 32, format('challan took stock out: %s', q);
  v_ch := save_challan(jsonb_build_object('id', v_ch, 'customer_id', v_cust, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 2)));
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_a; assert q = 320 - 64, format('edited challan re-posted: %s', q);
  select count(*) into n from stock_ledger where ref_table = 'delivery_challans' and ref_id = v_ch; assert n = 3, 'out, back, out — rows never edited';
  v_inv := convert_challan(v_ch, jsonb_build_object('transport_name', 'KPN'));
  select status::text, total, transport_name into r from invoices where id = v_inv; assert r.status = 'confirmed' and r.total = 2 * 32 * 44 and r.transport_name = 'KPN', format('challan invoice %s', to_jsonb(r));
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_a; assert q = 320 - 64, format('stock unchanged by billing: %s', q);
  select state::text, invoice_no into r from v_challan_list where id = v_ch; assert r.state = 'converted' and r.invoice_no is not null;
  v_ch2 := save_challan(jsonb_build_object('customer_id', v_cust, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_b, 'boxes', 1)));
  perform cancel_challan(v_ch2);
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_b; assert q = 0, 'cancelled challan nets to zero';
  assert trial_balance_check(v_org) = 0, 'TB after challan invoice';

  -- ===== purchase return / debit note =====
  select payable into q from v_supplier_list where id = v_sup;
  v_pr := save_purchase_return(jsonb_build_object('supplier_id', v_sup, 'purchase_id', v_doc, 'location_id', v_loc, 'notes', 'damaged bag'),
            jsonb_build_array(jsonb_build_object('item_id', v_a, 'qty', 32, 'rate', 30)));
  select total, return_no into r from v_purchase_return_list where id = v_pr; assert r.total = 960 and r.return_no is not null;
  select payable into r from v_supplier_list where id = v_sup; assert r.payable = q - 960, format('payable %s → %s', q, r.payable);
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_a; assert q = 320 - 64 - 32, format('stock after purchase return %s', q);
  select balance into q from v_trial_balance where org_id = v_org and code = 'PURCHASES'; assert q = 9600 - 960, format('purchases net of returns %s', q);
  assert trial_balance_check(v_org) = 0, 'TB at the end';

  reset role;
  raise notice 'OK: documents — price lists (customer → default → master, overrides win, bulk %%/copy, dates, assign by route, one default), schemes (item beats section, free line, 5%%), quotation → invoice untouched, sale order partial → completed with two invoices, purchase order → bill, WhatsApp order → sale order, challan out / edit / bill / cancel with rows never edited, purchase return debit note';
end $$;

rollback;
