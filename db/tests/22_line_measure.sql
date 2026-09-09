-- ============================================================
-- DB acceptance test: a unit that weighs nothing. Rolls back.
--
-- The bug this pins: save_quotation died with
--   23502  null value in column "qty_base" of relation "quotation_items"
-- when an item's stock unit had basis 'weight' and its grams left blank.
-- pieces_to_uom divided by nullif(weight_g, 0), handed back NULL, and the
-- NULL reached a NOT NULL constraint three tables away where nothing could
-- name the item or the empty box. Every assertion below fails before 29.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_kg uuid; v_cust uuid; v_weighed uuid; v_counted uuid;
  v_msg text; v_id uuid; v_base numeric;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_jar;
  -- The unit as Setup > Units will accept it today: weight basis, grams blank.
  insert into uoms (org_id, code, name, basis) values (v_org, 'KG', 'Kilogram', 'weight') returning id into v_kg;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, net_weight_g)
    values (v_org, 'W1', 'KAJU KATLI 250g', v_kg, 10, 1, 300, 250) returning id into v_weighed;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, 'C1', 'HT. MYSOOR PAK(12) 32', v_jar, 32, 12, 42) returning id into v_counted;

  -- 1. The conversion refuses, naming the unit and the item, instead of NULL.
  begin
    v_base := to_base_qty(v_weighed, 10, v_kg);
    raise exception '22.1 expected a raise, got %', coalesce(v_base::text, 'NULL');
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%"KG"%', format('22.1 does not name the unit: %s', v_msg);
    assert v_msg like '%KAJU KATLI%', format('22.1 does not name the item: %s', v_msg);
    assert v_msg like '%Setup > Units%', format('22.1 does not say where to fix it: %s', v_msg);
  end;

  -- 2. All the way up: save_quotation reports the cause, not the constraint.
  --    This is the exact call that failed in production.
  begin
    v_id := save_quotation(
      jsonb_build_object('customer_id', v_cust, 'quote_date', current_date::text),
      jsonb_build_array(jsonb_build_object('item_id', v_weighed, 'boxes', 2, 'rate', 300)));
    raise exception '22.2 expected save_quotation to raise, it returned %', v_id;
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg not like '%null value in column%', format('22.2 still the constraint, not the cause: %s', v_msg);
    assert v_msg like '%KAJU KATLI%', format('22.2 does not name the item: %s', v_msg);
  end;

  -- 3. The quieter half of the same bug: an unset kilogram used to be read as
  --    ONE GRAM, so the quantity came out a thousandfold wrong and saved
  --    happily. It must refuse rather than invent a weight.
  begin
    v_base := qty_to_pieces(v_weighed, 5, v_kg);
    raise exception '22.3 unset weight silently converted to % pieces', v_base;
  exception when sqlstate '23514' then null;
  end;

  -- 4. Filling the box in makes it work, and the arithmetic is the real one:
  --    5 kg of a 250 g pack is 20 pieces, and 1 kg back is 4 packs.
  update uoms set weight_g = 1000 where id = v_kg;
  assert qty_to_pieces(v_weighed, 5, v_kg) = 20,
    format('22.4 expected 20 pieces, got %s', qty_to_pieces(v_weighed, 5, v_kg));
  assert pieces_to_uom(v_weighed, 4, v_kg) = 1,
    format('22.4 expected 1 kg, got %s', pieces_to_uom(v_weighed, 4, v_kg));

  -- 5. An item with no stock unit at all names itself, rather than reporting
  --    "UOM <null> not found".
  update items set base_uom_id = null where id = v_weighed;
  begin
    v_base := to_base_qty(v_weighed, 4, null);
    raise exception '22.5 expected a raise, got %', coalesce(v_base::text, 'NULL');
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%no stock unit%', format('22.5 wrong message: %s', v_msg);
  end;

  -- 6. The whole master can be checked in one go.
  assert exists (select 1 from items_needing_measure() where item_code = 'W1'),
    '22.6 items_needing_measure() missed the item with no stock unit';
  update items set base_uom_id = v_kg where id = v_weighed;
  update uoms set weight_g = 0 where id = v_kg;
  assert exists (select 1 from items_needing_measure() where item_code = 'W1'),
    '22.6 items_needing_measure() missed the weightless unit';
  assert not exists (select 1 from items_needing_measure() where item_code = 'C1'),
    '22.6 items_needing_measure() reports a sound item';

  -- 7. Counted items were never affected and still convert exactly as before,
  --    so none of this changed a number anybody is already billing on.
  update uoms set weight_g = 1000 where id = v_kg;
  assert to_base_qty(v_counted, 64, v_jar) = 64, '22.7 a counted item stopped converting';
  v_id := save_quotation(
    jsonb_build_object('customer_id', v_cust, 'quote_date', current_date::text),
    jsonb_build_array(jsonb_build_object('item_id', v_counted, 'boxes', 2, 'rate', 42)));
  assert (select qty_base from quotation_items where quotation_id = v_id) = 64,
    '22.7 a sound line no longer converts to 64 jars';

  raise notice 'OK: line measure — a weight unit with no grams now names itself, the item and Setup > Units instead of dying on a NOT NULL constraint; an unset weight is refused rather than read as one gram; items_needing_measure() lists every affected item; counted items convert exactly as before';
end $$;

rollback;
