-- ============================================================
-- DB acceptance test: one party on both sides of the book.
--
-- The shop sells to people who also sell to it. Two unconnected rows meant
-- the subtraction was being done on paper, usually while the man stood there.
--
-- The two ledgers must stay correct on their own: the net is a third figure
-- derived from both, never a replacement for either, and unlinking must put
-- everything back exactly as it was.
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
  v_org uuid; v_jar uuid; v_loc uuid; v_item uuid; v_mode uuid;
  v_cust uuid; v_cust2 uuid; v_sup uuid; v_inv uuid; v_pur uuid;
  r record; q numeric; n int; v_msg text;
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
    values (v_org,v_item,v_loc,'opening',current_date-30, 100000);
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order)
    values (v_org,'CASH','Cash', true, false, 1) returning id into v_mode;

  -- SUBBA RAO buys sweets from the shop AND sells it groundnuts
  insert into customers (org_id, name, town) values (v_org,'SUBBA RAO','MACHERLA') returning id into v_cust;
  insert into suppliers (org_id, name, town) values (v_org,'SUBBA RAO (PV)','MACHERLA') returning id into v_sup;
  insert into customers (org_id, name) values (v_org,'RAVI STORES') returning id into v_cust2;

  -- he owes the shop 4,000 for sweets
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', (current_date-5)::text, 'location_id', v_loc),
                        jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 40, 'rate', 10)));
  perform set_invoice_status(v_inv, 'confirmed');
  -- the shop owes him 2,500 for groundnuts
  v_pur := save_purchase(jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', (current_date-3)::text),
                         jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 25, 'rate', 10)));

  -- ===== 57.1 unlinked, nothing changes =====
  select outstanding, payable, net_outstanding into r from v_customer_list where id = v_cust;
  assert r.outstanding = 4000, format('57.1 he owes 4000, shows %s', r.outstanding);
  assert r.payable = 0, format('57.1 unlinked, the shop owes him nothing on this row: %s', r.payable);
  assert r.net_outstanding = 4000, format('57.1 and the net is just the sales: %s', r.net_outstanding);

  -- ===== 57.2 linked, the net appears and the two parts survive =====
  select link_party(v_cust, v_sup) into v_msg;
  assert v_msg like '%one party%', format('57.2 %s', v_msg);
  select outstanding, payable, net_outstanding, supplier_name into r from v_customer_list where id = v_cust;
  assert r.outstanding = 4000, format('57.2 what he owes must not move: %s', r.outstanding);
  assert r.payable = 2500, format('57.2 what the shop owes him: %s', r.payable);
  assert r.net_outstanding = 1500, format('57.2 net is 4000 - 2500 = 1500, shows %s', r.net_outstanding);
  assert r.supplier_name = 'SUBBA RAO (PV)', '57.2 and names the other side';

  -- the supplier's own ledger is untouched by any of it
  assert supplier_payable(v_sup) = 2500, '57.2 the supplier side still stands alone';

  -- ===== 57.3 the shop owing more than it is owed reads as a negative net =====
  v_pur := save_purchase(jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', (current_date-2)::text),
                         jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 30, 'rate', 10)));
  select net_outstanding into q from v_customer_list where id = v_cust;
  assert q = 4000 - 2500 - 3000, format('57.3 the shop now owes him 1500 net, shows %s', q);

  -- ===== 57.4 the statement has both sides and nets as it goes =====
  select count(*) into n from party_statement(v_cust);
  assert n = 1 + 1 + 2, format('57.4 opening + one sale + two purchases = 4 rows, got %s', n);
  select balance into q from (select balance, entry_date, doc_no from party_statement(v_cust)) x
   order by entry_date desc nulls last, doc_no desc limit 1;
  assert q = -1500, format('57.4 the statement must close at the net: %s', q);
  select count(*) into n from party_statement(v_cust) where side = 'Sales';
  assert n = 1, '57.4 the sales side is still identifiable';
  select count(*) into n from party_statement(v_cust) where side = 'Purchases';
  assert n = 2, '57.4 so is the purchase side';

  -- money moving on either side moves the net
  perform save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date::text),
                       jsonb_build_array(jsonb_build_object('mode_id', v_mode, 'amount', 1000)));
  select net_outstanding into q from v_customer_list where id = v_cust;
  assert q = -2500, format('57.4 he paid 1000, so the shop owes 2500 net: %s', q);

  -- ===== 57.5 unlinking puts it all back =====
  select link_party(v_cust, null) into v_msg;
  assert v_msg like '%no longer linked%', format('57.5 %s', v_msg);
  select outstanding, payable, net_outstanding into r from v_customer_list where id = v_cust;
  assert r.outstanding = 3000, format('57.5 what he owes, unchanged by any of this: %s', r.outstanding);
  assert r.payable = 0 and r.net_outstanding = 3000, '57.5 and the net is the sales again';
  assert supplier_payable(v_sup) = 5500, '57.5 the supplier ledger never moved';

  -- ===== 57.6 one supplier row cannot belong to two parties =====
  perform link_party(v_cust, v_sup);
  begin
    perform link_party(v_cust2, v_sup);
    raise exception '57.6 the same supplier was tied to two customers';
  exception when sqlstate '23505' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%already linked%', format('57.6 wrong reason: %s', v_msg);
  end;

  -- ===== 57.7 a party with no other side is unaffected =====
  select outstanding, payable, net_outstanding into r from v_customer_list where id = v_cust2;
  assert r.payable = 0 and r.net_outstanding = r.outstanding, '57.7 an ordinary customer reads as it always did';
  select count(*) into n from party_statement(v_cust2);
  assert n = 1, format('57.7 and their statement is just an opening line, got %s rows', n);

  raise notice 'OK: a party who both buys and sells keeps two correct ledgers and gains a third figure from them — owes 4000, is owed 2500, nets 1500 — with sales and purchases still named separately on one statement that closes at the net; the net follows money on either side, a supplier row belongs to one party only, unlinking restores both ledgers untouched, and a party with one side reads exactly as before';
end $$;

rollback;
