-- ============================================================
-- DB acceptance test: removing a product outright. Rolls back.
--
-- This is the destructive one, so the test is mostly about what it will NOT do.
-- The whole value of it is that the line sits exactly where the money starts:
-- a product carrying nothing but the stock row that created it goes, and a
-- product on any document does not, however small that document is.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_cust uuid;
  v_junk uuid; v_sold uuid; v_quoted uuid; v_bare uuid; v_raw uuid; v_made uuid;
  v_msg text; n bigint; v_out text;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;

  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'99','ADDED BY MISTAKE', v_uom, 10, 1, 5) returning id into v_junk;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_uom, 32, 12, 42) returning id into v_sold;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'12','BOONDI LADDU (12) 48', v_uom, 48, 12, 40) returning id into v_quoted;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'77','NEVER TOUCHED', v_uom, 8, 1, 10) returning id into v_bare;

  -- 1. A product with nothing behind it at all.
  v_out := purge_item(v_bare);
  assert v_out like '%NEVER TOUCHED removed%', format('35.1 unexpected message: %s', v_out);
  assert not exists (select 1 from items where id = v_bare), '35.1 still there';

  -- 2. THE CASE THIS EXISTS FOR. A product carrying only the rows that created
  --    it: an import's opening row, and an adjustment somebody typed.
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table)
    values (v_org, v_junk, v_loc, 'opening', current_date, 100, 5, 'import');
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_junk, v_loc, 'adjustment', current_date, -10, 5);
  -- delete_master still refuses it — that has not changed and should not.
  begin
    perform delete_master('item', v_junk);
    raise exception '35.2 delete_master stopped refusing a product with stock';
  exception when sqlstate '23503' then null;
  end;

  v_out := purge_item(v_junk);
  assert v_out like '%2 stock movements%', format('35.2 does not say what went with it: %s', v_out);
  assert not exists (select 1 from items where id = v_junk), '35.2 the product is still there';
  assert not exists (select 1 from stock_ledger where item_id = v_junk), '35.2 its stock rows are still there';

  -- 3. A product on a BILL. Refused, named, and completely untouched.
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate)
    values (v_org, v_sold, v_loc, 'opening', current_date, 1000, 30);
  perform set_invoice_status(save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_sold, 'boxes', 2, 'rate', 42))), 'confirmed');
  begin
    perform purge_item(v_sold);
    raise exception '35.3 a product on a sale bill was purged';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%sale bill%', format('35.3 does not name what holds it: %s', v_msg);
    assert v_msg like '%inactive%', format('35.3 does not offer the way out: %s', v_msg);
  end;
  assert exists (select 1 from items where id = v_sold), '35.3 the product went anyway';
  select count(*) into n from stock_ledger where item_id = v_sold;
  assert n = 2, format('35.3 its stock was touched while being refused: %s rows', n);

  -- 4. A QUOTATION is enough. Nothing was sold, no stock moved, no money
  --    changed hands — and it still holds, because the paper went to a customer.
  perform save_quotation(
    jsonb_build_object('customer_id', v_cust, 'quote_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_quoted, 'boxes', 1, 'rate', 40)));
  begin
    perform purge_item(v_quoted);
    raise exception '35.4 a quoted product was purged';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%quotation%', format('35.4 wrong reason: %s', v_msg);
  end;

  -- 5. A raw material inside a recipe is held by the recipe, not by a bill.
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, type)
    values (v_org,'RM-BESAN','BESAN FLOUR', v_uom, 1, 1, 'raw_material') returning id into v_raw;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, type)
    values (v_org,'50','KAJU KATLI', v_uom, 10, 1, 'finished_good') returning id into v_made;
  perform save_recipe(
    jsonb_build_object('item_id', v_made, 'pieces_per_plate', 100),
    jsonb_build_array(jsonb_build_object('ingredient_id', v_raw, 'qty_per_plate', 5)));
  begin
    perform purge_item(v_raw);
    raise exception '35.5 an ingredient of a live recipe was purged';
  exception when sqlstate '23503' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%recipe%', format('35.5 wrong reason: %s', v_msg);
  end;

  -- 6. Gone means gone: a second go says so rather than reporting success.
  begin
    perform purge_item(v_junk);
    raise exception '35.6 purging a product twice reported success';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%not there any more%', format('35.6 wrong reason: %s', v_msg);
  end;

  raise notice 'OK: purge a product — one with nothing behind it goes, and so does one carrying only an import row and a typed adjustment, taking those rows with it and saying how many; a bill, a quotation and a recipe each hold it back by name with Set inactive offered, and a refused product keeps every stock row it had';
end $$;

rollback;
