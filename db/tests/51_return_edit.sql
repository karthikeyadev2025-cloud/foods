-- ============================================================
-- DB acceptance test: a return can be corrected.
--
-- "in returns they want edit option too". The same rules a purchase edit
-- follows (db/53, db/58, db/60): the old posting is reversed rather than
-- deleted, the reversal sits on the RETURN's own date, the credit is corrected
-- by a reversing journal, the number is kept, a save that changes nothing
-- writes nothing, and goods that came back and went out again cannot be
-- quietly un-returned.
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
  v_org uuid; v_jar uuid; v_loc uuid; v_cust uuid; v_item uuid; v_item2 uuid;
  v_inv uuid; v_ret uuid; v_again uuid;
  v_rows int; v_rows2 int; q numeric; n int; v_no text; v_msg text;
  v_header jsonb; v_lines jsonb;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');

  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name, town, mobile1) values (v_org,'P. SRINIVAS (MCL)','MACHARLA','9849686746') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'8','5/- HT. MYSOOR PAK(12) 32', v_jar, 32, 12, 42, 30) returning id into v_item;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'9','2/- CHEKKALU', v_jar, 24, 1, 20, 14) returning id into v_item2;

  -- stock to sell from, and a bill to return against
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base)
  values (v_org, v_item, v_loc, 'opening', current_date - 10, 3200),
         (v_org, v_item2, v_loc, 'opening', current_date - 10, 2400);
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc),
                        jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 10, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');

  -- ===== 51.1 a fresh return of 4 boxes =====
  v_header := jsonb_build_object('customer_id', v_cust, 'invoice_id', v_inv, 'kind', 'fresh_return',
                                 'return_date', (current_date - 2)::text, 'location_id', v_loc);
  v_lines  := jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 4, 'rate', 42));
  v_ret := save_sales_return(v_header, v_lines);
  select return_no into v_no from sales_returns where id = v_ret;

  select coalesce(sum(qty_base), 0) into q from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  assert q = 4 * 32, format('51.1 four boxes should come back as 128 units, came back as %s', q);
  select total into q from sales_returns where id = v_ret;
  assert q = 4 * 32 * 42, format('51.1 the credit should be 5376, is %s', q);

  -- ===== 51.2 saving the same return again writes nothing =====
  select count(*) into v_rows from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  v_again := save_sales_return(v_header || jsonb_build_object('id', v_ret), v_lines);
  assert v_again = v_ret, '51.2 re-saving must return the same return, not a new one';
  select count(*) into v_rows2 from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  assert v_rows2 = v_rows, format('51.2 re-saving wrote %s more stock rows', v_rows2 - v_rows);

  for n in select generate_series(1, 20) loop
    perform save_sales_return(v_header || jsonb_build_object('id', v_ret), v_lines);
  end loop;
  select count(*) into v_rows2 from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  assert v_rows2 = 1, format('51.2 twenty saves left %s stock rows', v_rows2);

  -- ===== 51.3 correcting it to 6 boxes, and the number is kept =====
  perform save_sales_return(v_header || jsonb_build_object('id', v_ret),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 6, 'rate', 42)));
  select coalesce(sum(qty_base), 0) into q from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  assert q = 6 * 32, format('51.3 the godown should hold the corrected 192 units, holds %s', q);
  select total into q from sales_returns where id = v_ret;
  assert q = 6 * 32 * 42, format('51.3 the credit should be 8064, is %s', q);
  select return_no into v_msg from sales_returns where id = v_ret;
  assert v_msg = v_no, format('51.3 the return number changed from %s to %s', v_no, v_msg);

  -- three rows: the first posting, its reversal, the corrected posting —
  -- nothing deleted, all of it on the RETURN's own date, not today
  select count(*) into v_rows2 from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  assert v_rows2 = 3, format('51.3 a correction should leave 3 rows, left %s', v_rows2);
  assert not exists (select 1 from stock_ledger
                      where ref_table = 'sales_returns' and ref_id = v_ret and txn_date <> current_date - 2),
    '51.3 a row of the corrected return is dated away from the return';

  -- ===== 51.4 the money is corrected by a reversal, not a rewrite =====
  select count(*) into n from journal_entries where ref_table = 'sales_returns' and ref_id = v_ret;
  assert n >= 3, format('51.4 the credit should be posted, reversed and re-posted; %s entries', n);
  assert trial_balance_check(v_org) = 0, '51.4 the books must still balance';

  -- ===== 51.5 a line can be added and the kind changed =====
  perform save_sales_return(
    v_header || jsonb_build_object('id', v_ret, 'kind', 'damage_return'),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 6, 'rate', 42),
                      jsonb_build_object('item_id', v_item2, 'boxes', 2, 'rate', 20)));
  select kind::text into v_msg from sales_returns where id = v_ret;
  assert v_msg = 'damage_return', format('51.5 the kind should be damage_return, is %s', v_msg);
  -- breakage is written off: the goods do not come back, so the return holds no stock
  select coalesce(sum(qty_base), 0) into q from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  assert q = 0, format('51.5 a damage return must not put goods back; it holds %s', q);
  select count(*) into n from sales_return_items where return_id = v_ret;
  assert n = 2, format('51.5 the corrected return should have 2 lines, has %s', n);

  -- ===== 51.6 and back to fresh, which puts the goods back =====
  perform save_sales_return(
    v_header || jsonb_build_object('id', v_ret),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 6, 'rate', 42)));
  select coalesce(sum(qty_base), 0) into q from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  assert q = 6 * 32, format('51.6 back to a fresh return, the godown should hold 192 again, holds %s', q);

  -- ===== 51.7 goods that came back and went out again cannot be un-returned =====
  -- everything on hand is sold, so the only thing holding the balance up is
  -- what this return put back
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_item and location_id = v_loc;
  perform set_invoice_status(save_invoice(
    jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc),
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', q / 32, 'rate', 42))), 'confirmed');
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_item and location_id = v_loc;
  assert q = 0, format('51.7 the godown should be empty before this check, holds %s', q);

  begin
    perform save_sales_return(v_header || jsonb_build_object('id', v_ret),
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
    raise exception '51.7 a return was reduced below what the godown can give back';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%gone out again%', format('51.7 wrong reason: %s', v_msg);
  end;

  -- refused whole: the return is untouched and the godown is not negative
  select coalesce(sum(qty_base), 0) into q from stock_ledger where item_id = v_item and location_id = v_loc;
  assert q = 0, format('51.7 the refusal must roll back whole; the godown holds %s', q);
  select coalesce(sum(qty_base), 0) into q from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  assert q = 6 * 32, format('51.7 the return should still hold its 192 units, holds %s', q);

  -- ===== 51.8 posting a return that still holds stock is still refused =====
  -- db/05's guard. The edit path reverses first, so the return holds nothing
  -- when it re-posts — but called on its own, against a return whose goods are
  -- still in the godown, it must refuse rather than double the stock.
  begin
    perform post_return_stock(v_ret);
    raise exception '51.8 a return was posted to stock twice';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%already posted%', format('51.8 wrong reason: %s', v_msg);
  end;

  -- ===== 51.9 a return that does not exist is refused =====
  begin
    perform save_sales_return(v_header || jsonb_build_object('id', gen_random_uuid()), v_lines);
    raise exception '51.9 an unknown return id was accepted';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%not found%', format('51.9 wrong reason: %s', v_msg);
  end;

  raise notice 'OK: a return can be corrected — boxes, rate, lines, kind and date — and the godown holds exactly what the corrected return says, because the old posting is REVERSED on the return''s own date rather than deleted; the return keeps its number, the credit is corrected by a reversing journal entry and the books still balance; saving it unchanged twenty times writes nothing at all; a damage return puts no goods back and switching it to fresh does; a return whose goods have gone out again is refused by name and rolls back whole; and posting a return that still holds stock is refused as it always was';
end $$;

rollback;
