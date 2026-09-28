-- ============================================================
-- DB acceptance test: a document's lines keep the order they were typed in.
-- Rolls back.
--
-- The fault was invisible to every existing test, because they all asked "is
-- this line on the bill?" and never "is it the third one?". A primary key of
-- gen_random_uuid() ordered by id is a shuffle, so the bill the shop printed
-- listed its items in an order nobody had chosen.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_loc uuid; v_cust uuid; v_sup uuid; v_sec uuid;
  v_inv uuid; v_pur uuid; n int;
  ids uuid[] := '{}';
  codes text[];
  uid uuid := gen_random_uuid();
  i int;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into sections (org_id, name) values (v_org,'OUTER') returning id into v_sec;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'P. SRINIVAS (MCL)') returning id into v_cust;
  insert into suppliers (org_id, name) values (v_org,'SUGAR TRADERS') returning id into v_sup;

  --    Twenty products. Few enough to read, many enough that coming back in
  --    the typed order by luck is not worth considering.
  for i in 1..20 loop
    insert into items (org_id, item_code, name, section_id, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
      values (v_org, lpad(i::text, 4, '0'), 'ITEM ' || lpad(i::text, 4, '0'), v_sec, v_jar, 12, 1, 15, 10)
      returning id into v_pur;   -- reused as scratch
    ids := ids || v_pur;
  end loop;
  v_pur := null;

  -- ============================================================
  -- 1. A PURCHASE COMES BACK IN THE ORDER IT WAS TYPED.
  --    The lines go in DELIBERATELY not in code order — 20 first, 1 last —
  --    so that a report sorted by code, or by id, or by anything other than
  --    what was typed, fails here.
  -- ============================================================
  v_pur := save_purchase(
    jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    (select jsonb_agg(jsonb_build_object('item_id', ids[21 - g], 'boxes', g, 'rate', 10) order by g)
       from generate_series(1, 20) g));

  select array_agg(item_code order by line_no) into codes
    from v_purchase_lines where purchase_id = v_pur;
  assert codes[1] = '0020', format('47.1 the first line typed came back as %s', codes[1]);
  assert codes[20] = '0001', format('47.20 the last line typed came back as %s', codes[20]);

  --    Every position, not just the ends.
  for i in 1..20 loop
    assert codes[i] = lpad((21 - i)::text, 4, '0'),
      format('47.1 line %s reads %s, not %s', i, codes[i], lpad((21 - i)::text, 4, '0'));
  end loop;

  --    Numbered 1..20 with no gaps and no repeats — a screen that prints the
  --    line number would otherwise show "1 2 2 4".
  select count(distinct line_no) into n from purchase_items where purchase_id = v_pur;
  assert n = 20, format('47.2 %s distinct line numbers for 20 lines', n);
  select min(line_no) into n from purchase_items where purchase_id = v_pur;
  assert n = 1, format('47.2 numbering starts at %s', n);
  select max(line_no) into n from purchase_items where purchase_id = v_pur;
  assert n = 20, format('47.2 numbering ends at %s', n);

  -- ============================================================
  -- 2. CORRECTING THE BILL RE-NUMBERS IT. After an edit the order on the
  --    screen IS the order, so it starts again at 1 in the new sequence.
  -- ============================================================
  perform save_purchase(
    jsonb_build_object('id', v_pur, 'location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
    jsonb_build_array(
      jsonb_build_object('item_id', ids[5], 'boxes', 1, 'rate', 10),
      jsonb_build_object('item_id', ids[9], 'boxes', 2, 'rate', 10),
      jsonb_build_object('item_id', ids[1], 'boxes', 3, 'rate', 10)));

  select array_agg(item_code order by line_no) into codes
    from v_purchase_lines where purchase_id = v_pur;
  assert codes = array['0005','0009','0001'], format('47.3 after the edit the lines read %s', codes);
  select max(line_no) into n from purchase_items where purchase_id = v_pur;
  assert n = 3, format('47.3 the re-saved bill numbers up to %s, not 3', n);

  -- ============================================================
  -- 3. A SALES INVOICE TOO. The shop's own bill printing out of order is
  --    worse than a purchase doing it.
  -- ============================================================
  v_inv := save_invoice(
    jsonb_build_object('customer_id', v_cust, 'location_id', v_loc, 'invoice_date', current_date::text),
    (select jsonb_agg(jsonb_build_object('item_id', ids[21 - g], 'boxes', g, 'rate', 15) order by g)
       from generate_series(1, 20) g));

  select array_agg(item_code order by line_no) into codes from v_invoice_lines where invoice_id = v_inv;
  for i in 1..20 loop
    assert codes[i] = lpad((21 - i)::text, 4, '0'),
      format('47.4 invoice line %s reads %s, not %s', i, codes[i], lpad((21 - i)::text, 4, '0'));
  end loop;

  --    And a confirmed bill keeps that order — posting stock must not disturb it.
  perform set_invoice_status(v_inv, 'confirmed');
  select array_agg(item_code order by line_no) into codes from v_invoice_lines where invoice_id = v_inv;
  assert codes[1] = '0020', format('47.5 confirming the bill reordered it: first line is %s', codes[1]);

  -- ============================================================
  -- 4. TWO DOCUMENTS NUMBER THEMSELVES INDEPENDENTLY. A shared counter would
  --    have the second bill starting at 21.
  -- ============================================================
  select min(line_no) into n from invoice_items where invoice_id = v_inv;
  assert n = 1, format('47.6 the second document started numbering at %s', n);

  -- ============================================================
  -- 5. A LINE NUMBER GIVEN BY THE CALLER IS KEPT, so an importer that knows
  --    the order from the spreadsheet can say so.
  -- ============================================================
  insert into purchase_items (purchase_id, item_id, boxes, qty, uom_id, qty_base, rate, amount, line_no)
  values (v_pur, ids[2], 1, 12, v_jar, 12, 10, 120, 99);
  select line_no into n from purchase_items where purchase_id = v_pur and item_id = ids[2];
  assert n = 99, format('47.7 a line number that was given was overwritten with %s', n);

  --    And the next one after it carries on from there rather than colliding.
  insert into purchase_items (purchase_id, item_id, boxes, qty, uom_id, qty_base, rate, amount)
  values (v_pur, ids[3], 1, 12, v_jar, 12, 10, 120);
  select line_no into n from purchase_items where purchase_id = v_pur and item_id = ids[3];
  assert n = 100, format('47.7 the next line took %s rather than 100', n);

  raise notice 'OK: document lines keep the order they were typed — a purchase of twenty lines entered against the code order comes back in the typed order at every position, numbered 1..20 with no gaps; correcting a bill re-numbers it to the new order; a sales invoice does the same and confirming it does not disturb the order; each document numbers itself from 1; and a line number supplied by the caller is kept, with the next line carrying on past it';
end $$;

rollback;
