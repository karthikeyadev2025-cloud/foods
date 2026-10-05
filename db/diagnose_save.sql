-- ============================================================
-- JYOTHI FOODS ERP — WHERE DOES A PURCHASE SAVE SPEND ITS TIME?
--
-- Paste the whole file into the Supabase SQL editor and send one screenshot.
--
-- IT CHANGES NOTHING. The whole thing runs inside a transaction that is rolled
-- back at the end: no purchase is created, no stock moves, no number is used
-- up. Run it in the middle of the day if you like.
--
-- Why this exists: the same save takes 40ms on a database built here with four
-- hundred purchases, and over two minutes on yours — statement_timeout there is
-- 120 seconds and it is being hit. That is not "a bit slow", it is one step
-- going badly wrong, and this says which one.
--
-- Read the `ms` column. One row will be enormous and the rest will be nothing.
-- ============================================================

begin;

do $$
declare
  v_org uuid; v_uid uuid; v_loc uuid; v_item uuid; v_sup uuid;
  t0 timestamptz; t1 timestamptz;
  v_no text; v_pur uuid; v_entry uuid; n bigint; v_net numeric;
  results text[] := '{}';
  step text;
begin
  select auth_uid, org_id into v_uid, v_org from staff where auth_uid is not null limit 1;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  set local role authenticated;

  select id into v_loc from stock_locations where org_id = v_org and is_active limit 1;
  select id into v_item from items where org_id = v_org and is_active limit 1;
  select id into v_sup from suppliers where org_id = v_org and is_active limit 1;

  if v_loc is null or v_item is null then
    raise notice 'CANNOT RUN: this shop has no godown or no products yet.';
    return;
  end if;

  -- 1. The purchase number. Takes a lock on number_series and then looks for a
  --    number nobody has used.
  t0 := clock_timestamp();
  v_no := next_doc_no(v_org, 'purchase');
  t1 := clock_timestamp();
  results := results || format('%-34s %10s ms', 'next_doc_no(purchase)', round(extract(epoch from (t1 - t0)) * 1000));

  -- 2. The journal number. save_purchase takes this one too, through
  --    post_journal — a second lock, on a row every document type shares.
  t0 := clock_timestamp();
  perform next_doc_no(v_org, 'journal');
  t1 := clock_timestamp();
  results := results || format('%-34s %10s ms', 'next_doc_no(journal)', round(extract(epoch from (t1 - t0)) * 1000));

  -- 3. Reading the stock ledger the way posting does. This is the table that
  --    showed 33 MB against 4 rows.
  t0 := clock_timestamp();
  select coalesce(sum(qty_base), 0) into v_net
    from stock_ledger where ref_table = 'purchases' and ref_id = gen_random_uuid();
  t1 := clock_timestamp();
  results := results || format('%-34s %10s ms', 'read stock_ledger by ref', round(extract(epoch from (t1 - t0)) * 1000));

  -- 4. And by item, which is what the stock figures and the edit path do.
  t0 := clock_timestamp();
  select coalesce(sum(qty_base), 0) into v_net
    from stock_ledger where item_id = v_item and location_id = v_loc;
  t1 := clock_timestamp();
  results := results || format('%-34s %10s ms', 'read stock_ledger by item', round(extract(epoch from (t1 - t0)) * 1000));

  -- 5. Counting it outright — how long one pass over the whole table takes.
  t0 := clock_timestamp();
  select count(*) into n from stock_ledger;
  t1 := clock_timestamp();
  results := results || format('%-34s %10s ms  (%s rows)', 'count stock_ledger', round(extract(epoch from (t1 - t0)) * 1000), n);

  -- 6. The ledger posting on its own.
  t0 := clock_timestamp();
  v_entry := post_journal(v_org, current_date, 'TIMING TEST — rolled back', 'purchases', gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('account','PURCHASES','debit',1),
                      jsonb_build_object('account','CREDITORS','credit',1)));
  t1 := clock_timestamp();
  results := results || format('%-34s %10s ms', 'post_journal', round(extract(epoch from (t1 - t0)) * 1000));

  -- 7. The whole thing, one line, exactly as the screen calls it.
  t0 := clock_timestamp();
  begin
    v_pur := save_purchase(
      jsonb_build_object('location_id', v_loc, 'supplier_id', v_sup, 'bill_date', current_date::text),
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 1, 'rate', 1)));
    t1 := clock_timestamp();
    results := results || format('%-34s %10s ms', 'save_purchase (1 line)', round(extract(epoch from (t1 - t0)) * 1000));
  exception when others then
    t1 := clock_timestamp();
    get stacked diagnostics step = message_text;
    results := results || format('%-34s %10s ms  FAILED: %s', 'save_purchase (1 line)',
                                 round(extract(epoch from (t1 - t0)) * 1000), step);
  end;

  foreach step in array results loop
    raise notice '%', step;
  end loop;
  raise notice '--- nothing above was kept; this transaction rolls back ---';
end $$;

rollback;
