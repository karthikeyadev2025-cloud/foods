-- ============================================================
-- DB acceptance test: saving a purchase that has not changed writes nothing.
--
-- The shop's ledger had one bill holding 127 rows for a single product — 64
-- postings and 63 reversals — because the same save ran over and over. The
-- balance was right and the ledger was 127 times too long, which is what made
-- a save slow enough to time out, which is what made it run again.
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
  v_org uuid; v_jar uuid; v_loc uuid; v_sup uuid; v_item uuid; v_item2 uuid;
  v_pur uuid; v_again uuid; v_rows int; v_jl int; v_rows2 int; v_jl2 int; q numeric;
  v_payload jsonb; v_lines jsonb;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');

  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into suppliers (org_id, name) values (v_org,'SUBBA RAO GARU') returning id into v_sup;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'69','5/- SP PALLI VUNDALU (12) 60', v_jar, 60, 1, 1.50, 1) returning id into v_item;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'70','5/- NOOGU UNDALU (60)', v_jar, 60, 1, 1.50, 1) returning id into v_item2;

  v_lines := jsonb_build_array(
    jsonb_build_object('item_id', v_item,  'boxes', 9, 'rate', 1),
    jsonb_build_object('item_id', v_item2, 'boxes', 9, 'rate', 1));
  v_payload := jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup,
                                  'bill_no', '{12/10/26}/04', 'bill_date', current_date::text);

  v_pur := save_purchase(v_payload, v_lines);

  select count(*) into v_rows from stock_ledger where ref_table = 'purchases' and ref_id = v_pur;
  select count(*) into v_jl   from journal_lines jl join journal_entries je on je.id = jl.entry_id
   where je.ref_table = 'purchases' and je.ref_id = v_pur;
  assert v_rows = 2, format('50.1 a two-line bill posts 2 stock rows, posted %s', v_rows);
  assert v_jl > 0, '50.1 the bill posts a journal entry';

  -- ===== 50.2 the same bill saved again changes nothing =====
  v_again := save_purchase(v_payload || jsonb_build_object('id', v_pur), v_lines);
  assert v_again = v_pur, '50.2 re-saving must return the same bill, not a new one';

  select count(*) into v_rows2 from stock_ledger where ref_table = 'purchases' and ref_id = v_pur;
  select count(*) into v_jl2   from journal_lines jl join journal_entries je on je.id = jl.entry_id
   where je.ref_table = 'purchases' and je.ref_id = v_pur;
  assert v_rows2 = v_rows, format('50.2 re-saving wrote %s more stock rows', v_rows2 - v_rows);
  assert v_jl2 = v_jl, format('50.2 re-saving wrote %s more journal lines', v_jl2 - v_jl);

  -- ===== 50.3 sixty-four times over is still two rows =====
  for q in select generate_series(1, 64) loop
    perform save_purchase(v_payload || jsonb_build_object('id', v_pur), v_lines);
  end loop;
  select count(*) into v_rows2 from stock_ledger where ref_table = 'purchases' and ref_id = v_pur;
  assert v_rows2 = 2, format('50.3 sixty-four saves left %s stock rows — this is the shop''s bug', v_rows2);

  -- ===== 50.4 the same bill sent as quantities rather than boxes is the same bill =====
  -- 9 boxes of 60 is 540, and the screen may send either.
  perform save_purchase(v_payload || jsonb_build_object('id', v_pur),
    jsonb_build_array(jsonb_build_object('item_id', v_item,  'qty', 540, 'rate', 1),
                      jsonb_build_object('item_id', v_item2, 'qty', 540, 'rate', 1)));
  select count(*) into v_rows2 from stock_ledger where ref_table = 'purchases' and ref_id = v_pur;
  assert v_rows2 = 2, format('50.4 the same bill in quantities counted as a change, leaving %s rows', v_rows2);

  -- ===== 50.5 the order the lines are sent in is not a change =====
  perform save_purchase(v_payload || jsonb_build_object('id', v_pur),
    jsonb_build_array(jsonb_build_object('item_id', v_item2, 'boxes', 9, 'rate', 1),
                      jsonb_build_object('item_id', v_item,  'boxes', 9, 'rate', 1)));
  select count(*) into v_rows2 from stock_ledger where ref_table = 'purchases' and ref_id = v_pur;
  assert v_rows2 = 2, format('50.5 reordering the lines counted as a change, leaving %s rows', v_rows2);

  -- ===== 50.6 a real correction still corrects =====
  perform save_purchase(v_payload || jsonb_build_object('id', v_pur),
    jsonb_build_array(jsonb_build_object('item_id', v_item,  'boxes', 15, 'rate', 1),
                      jsonb_build_object('item_id', v_item2, 'boxes', 9,  'rate', 1)));
  select coalesce(sum(qty_base), 0) into q from stock_ledger
   where ref_table = 'purchases' and ref_id = v_pur and item_id = v_item;
  assert q = 15 * 60, format('50.6 the corrected bill should hold 900 units, holds %s', q);
  select coalesce(sum(qty_base), 0) into q from stock_ledger
   where ref_table = 'purchases' and ref_id = v_pur and item_id = v_item2;
  assert q = 9 * 60, format('50.6 the untouched line should still hold 540 units, holds %s', q);
  -- one reversal and one fresh posting per product, on top of the original two
  select count(*) into v_rows2 from stock_ledger where ref_table = 'purchases' and ref_id = v_pur;
  assert v_rows2 = 6, format('50.6 a correction should leave 6 rows, left %s', v_rows2);

  -- ===== 50.7 and saving THAT again is a no-op too =====
  perform save_purchase(v_payload || jsonb_build_object('id', v_pur),
    jsonb_build_array(jsonb_build_object('item_id', v_item,  'boxes', 15, 'rate', 1),
                      jsonb_build_object('item_id', v_item2, 'boxes', 9,  'rate', 1)));
  select count(*) into v_rows2 from stock_ledger where ref_table = 'purchases' and ref_id = v_pur;
  assert v_rows2 = 6, format('50.7 re-saving the corrected bill left %s rows', v_rows2);

  -- ===== 50.8 a change to the header alone is still a change =====
  perform save_purchase(v_payload || jsonb_build_object('id', v_pur, 'other_charges', 50),
    jsonb_build_array(jsonb_build_object('item_id', v_item,  'boxes', 15, 'rate', 1),
                      jsonb_build_object('item_id', v_item2, 'boxes', 9,  'rate', 1)));
  select other_charges into q from purchases where id = v_pur;
  assert q = 50, format('50.8 other charges should be 50, are %s', q);

  raise notice 'OK: a purchase saved again without being changed writes nothing — not a stock row, not a journal line, not a new bill — whether the lines arrive as boxes or quantities and in any order; sixty-four such saves leave the two rows the bill started with, while a real correction still reverses and re-posts, and a change to the header alone is still a change';
end $$;

rollback;
