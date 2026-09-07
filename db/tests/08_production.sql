-- ============================================================
-- DB acceptance test: T4 production.
-- Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_kg uuid; v_loc uuid; v_laddu uuid; v_sugar uuid; v_besan uuid; v_recipe uuid; v_batch uuid; v_old uuid;
  v_sec uuid; v_mestri uuid; v_chief uuid; r record; n int; q numeric;
  uid_head uuid := gen_random_uuid(); uid_chief uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_head::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_jar;
  insert into uoms (org_id, code, name, basis, weight_g) values (v_org, 'KG', 'Kilogram', 'weight', 1000) returning id into v_kg;
  insert into stock_locations (org_id, name, kind) values (v_org, 'Production floor', 'production_floor') returning id into v_loc;
  insert into staff (org_id, full_name, role, is_mestry) values (v_org, 'RAMA KRISHNA', 'production_head', true) returning id into v_mestri;
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_chief, 'Chief Babu', 'chief') returning id into v_chief;
  insert into sections (org_id, code, name, mestri_id) values (v_org, 'S-10', 'RAMA KRISHNA MESTRI', v_mestri) returning id into v_sec;
  -- 5/- BOONDI LADDU (8): 8 jars per box, 8 pieces per jar = 64 pieces per box
  insert into items (org_id, item_code, name, base_uom_id, section_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '1', '5/- BOONDI LADDU (8)', v_jar, v_sec, 8, 8, 120) returning id into v_laddu;
  insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit, purchase_rate)
    values (v_org, 'RM-SUGAR', 'SUGAR', 'raw_material', v_kg, 1, 1, 42) returning id into v_sugar;
  insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit, purchase_rate)
    values (v_org, 'RM-BESAN', 'BESAN', 'raw_material', v_kg, 1, 1, 90) returning id into v_besan;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, qty_base) values (v_org, v_sugar, v_loc, 'opening', 100), (v_org, v_besan, v_loc, 'opening', 50);

  -- ===== T4.1 recipe =====
  begin
    perform open_production_batch(jsonb_build_object('item_id', v_laddu, 'plates', 10, 'location_id', v_loc));
    raise exception 'batch without a recipe must fail';
  exception when others then if sqlerrm not like '%no active recipe%' then raise; end if;
  end;
  v_recipe := save_recipe(jsonb_build_object('item_id', v_laddu, 'pieces_per_plate', 96),
                          jsonb_build_array(jsonb_build_object('ingredient_id', v_sugar, 'qty_per_plate', 2),
                                            jsonb_build_object('ingredient_id', v_besan, 'qty_per_plate', 1.5)));
  select ingredient_count, boxes_per_plate, cost_per_plate into r from v_recipe_list where id = v_recipe;
  assert r.ingredient_count = 2 and r.boxes_per_plate = 1.5 and r.cost_per_plate = 2 * 42 + 1.5 * 90,
    format('recipe: %s ingredients, %s boxes/plate, cost %s', r.ingredient_count, r.boxes_per_plate, r.cost_per_plate);
  begin
    perform save_recipe(jsonb_build_object('item_id', v_laddu, 'pieces_per_plate', 96),
                        jsonb_build_array(jsonb_build_object('ingredient_id', v_laddu, 'qty_per_plate', 1)));
    raise exception 'a finished good as an ingredient must fail';
  exception when others then if sqlerrm not like '%is a finished good%' then raise; end if;
  end;
  -- a new recipe for the same item retires the old one
  v_old := v_recipe;
  v_recipe := save_recipe(jsonb_build_object('item_id', v_laddu, 'pieces_per_plate', 96),
                          jsonb_build_array(jsonb_build_object('ingredient_id', v_sugar, 'qty_per_plate', 2),
                                            jsonb_build_object('ingredient_id', v_besan, 'qty_per_plate', 1.5)));
  select count(*) into n from recipes where item_id = v_laddu and is_active; assert n = 1, 'one active recipe per item';

  -- ===== T4.2 open: expected column rides on the master =====
  v_batch := open_production_batch(jsonb_build_object('item_id', v_laddu, 'plates', 10, 'location_id', v_loc,
                                                       'chief_id', v_chief, 'no_of_workers', 6, 'mestry_count', 1, 'labour_count', 5));
  select * into r from v_batch_list where id = v_batch;
  assert r.batch_no = '0001' and r.status = 'open', format('batch %s %s', r.batch_no, r.status);
  assert r.expected_pieces = 960 and r.expected_jars = 120 and r.expected_boxes = 15,
    format('expected: %s pieces, %s jars, %s boxes', r.expected_pieces, r.expected_jars, r.expected_boxes);
  assert r.mestri_name = 'RAMA KRISHNA' and r.chief_name = 'Chief Babu';
  select total_usage_per_plate, rate into r from v_batch_ingredients where batch_id = v_batch and item_code = 'RM-SUGAR';
  assert r.total_usage_per_plate = 20 and r.rate = 42, format('sugar expected %s @ %s', r.total_usage_per_plate, r.rate);
  begin
    perform close_production_batch(v_batch);
    raise exception 'closing without actual boxes must fail';
  exception when others then if sqlerrm not like '%actual boxes%' then raise; end if;
  end;

  -- ===== T4.3 the chief: sees today's open batch only, enters actuals, cannot close =====
  perform set_config('request.jwt.claim.sub', uid_chief::text, true);
  select count(*) into n from production_batches; assert n = 1, 'chief sees today''s open batch';
  select count(*) into n from v_batch_ingredients where batch_id = v_batch; assert n = 2, 'and its sheet';
  perform update_batch_actuals(v_batch, jsonb_build_object(
    'actual_boxes', 14, 'no_of_workers', 6, 'labour_cost', 1800,
    'lines', (select jsonb_agg(jsonb_build_object('id', id, 'actual_qty', case item_code when 'RM-SUGAR' then 21 else 15.5 end))
              from v_batch_ingredients where batch_id = v_batch)));
  select difference into q from v_batch_ingredients where batch_id = v_batch and item_code = 'RM-SUGAR';
  assert q = 1, format('sugar difference should be +1 kg, got %s', q);
  select actual_pieces, actual_jars, box_difference into r from v_batch_list where id = v_batch;
  assert r.actual_jars = 112 and r.actual_pieces = 896 and r.box_difference = -1,
    format('actuals: %s jars %s pieces diff %s', r.actual_jars, r.actual_pieces, r.box_difference);
  begin
    perform close_production_batch(v_batch);
    raise exception 'chief must not close';
  exception when others then if sqlerrm not like '%production head closes%' then raise; end if;
  end;
  begin
    perform open_production_batch(jsonb_build_object('item_id', v_laddu, 'plates', 1, 'location_id', v_loc));
    raise exception 'chief must not open';
  exception when others then if sqlerrm not like '%production head opens%' then raise; end if;
  end;

  -- ===== close: consume, add, cost =====
  perform set_config('request.jwt.claim.sub', uid_head::text, true);
  perform close_production_batch(v_batch);
  select sum(qty_base) into q from stock_ledger where item_id = v_sugar; assert q = 100 - 21, format('sugar stock %s', q);
  select sum(qty_base) into q from stock_ledger where item_id = v_besan; assert q = 50 - 15.5, format('besan stock %s', q);
  select sum(qty_base) into q from stock_ledger where item_id = v_laddu; assert q = 112, format('laddu stock should be 14 boxes = 112 jars, got %s', q);
  select ingredient_cost, labour_cost, total_cost, cost_per_box, status into r from v_batch_list where id = v_batch;
  assert r.ingredient_cost = 21 * 42 + 15.5 * 90 and r.labour_cost = 1800 and r.total_cost = r.ingredient_cost + 1800 and r.status = 'closed',
    format('cost: ing %s labour %s total %s', r.ingredient_cost, r.labour_cost, r.total_cost);
  assert r.cost_per_box = round((21 * 42 + 15.5 * 90 + 1800) / 14, 2), format('cost per box %s', r.cost_per_box);
  begin
    perform update_batch_actuals(v_batch, jsonb_build_object('actual_boxes', 99));
    raise exception 'actuals must freeze after close';
  exception when others then if sqlerrm not like '%frozen%' then raise; end if;
  end;

  -- the chief no longer sees it (closed), nor yesterday's open batch
  v_old := open_production_batch(jsonb_build_object('item_id', v_laddu, 'plates', 2, 'location_id', v_loc, 'production_date', current_date - 1));
  perform set_config('request.jwt.claim.sub', uid_chief::text, true);
  select count(*) into n from production_batches; assert n = 0, format('chief should see nothing now, sees %s', n);
  perform set_config('request.jwt.claim.sub', uid_head::text, true);
  perform cancel_production_batch(v_old);

  -- ===== T4.4 variance =====
  select * into r from production_variance(v_org, current_date - 7, current_date, 'item');
  assert r.group_key = '1' and r.batches = 1 and r.expected_boxes = 15 and r.actual_boxes = 14 and r.box_variance = -1
     and r.box_variance_pct = round(-100.0 / 15, 2) and r.expected_ingredient_cost = 20 * 42 + 15 * 90 and r.actual_ingredient_cost = 21 * 42 + 15.5 * 90,
    format('variance by item: %s', to_jsonb(r));
  select group_label into r from production_variance(v_org, current_date - 7, current_date, 'mestri');
  assert r.group_label = 'RAMA KRISHNA', format('by mestri: %s', r.group_label);
  select count(*) into n from production_variance(v_org, current_date - 7, current_date, 'week'); assert n = 1;

  reset role;
  raise notice 'OK: production — recipe explodes to 15 expected boxes, chief actuals (+1 kg sugar, 14 boxes), close consumes RM and adds FG at cost; chief sees only today''s open batch';
end $$;

rollback;
