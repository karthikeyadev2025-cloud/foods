-- ============================================================
-- DB acceptance test: recipes from a spreadsheet. Rolls back.
--
-- Recipes are the first import whose rows are not independent, so the things
-- worth proving are all about the grouping: rows scattered through the file
-- still make ONE recipe, pieces-per-plate written once covers the group, and a
-- bad ingredient loses its own recipe without taking the others down with it.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_jar uuid; v_kg uuid; v_g uuid; v_pack uuid;
  v_mysore uuid; v_laddu uuid; v_besan uuid; v_sugar uuid; v_ghee uuid;
  j jsonb; n bigint; v_rec uuid; v_err text; v_qty numeric; v_uom uuid;
  uid_owner uuid := gen_random_uuid();
  rows jsonb;
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into uoms (org_id, code, name, basis, weight_g) values (v_org,'KG','Kilogram','weight',1000) returning id into v_kg;
  insert into uoms (org_id, code, name, basis, weight_g) values (v_org,'G','Gram','weight',1) returning id into v_g;
  insert into pack_types (org_id, code) values (v_org,'JAR') returning id into v_pack;

  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, type)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_jar, 32, 12, 'finished_good') returning id into v_mysore;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, type)
    values (v_org,'12','BOONDI LADDU (12) 48', v_jar, 48, 12, 'finished_good') returning id into v_laddu;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, type)
    values (v_org,'RM-BESAN','BESAN FLOUR', v_kg, 1, 1, 'raw_material') returning id into v_besan;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, type)
    values (v_org,'RM-SUGAR','SUGAR', v_kg, 1, 1, 'raw_material') returning id into v_sugar;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, type)
    values (v_org,'RM-GHEE','GHEE', v_kg, 1, 1, 'raw_material') returning id into v_ghee;

  -- A sheet as a person would really hand it over: pieces-per-plate written on
  -- the first line of each recipe only, and — the awkward part — the rows for
  -- product 8 NOT kept together, because the sheet was sorted by ingredient.
  rows := jsonb_build_array(
    jsonb_build_object('item_code','8', 'pieces_per_plate','320','ingredient_code','RM-BESAN','qty_per_plate','12','uom','KG','name','MYSORE PAK PLATE'),
    jsonb_build_object('item_code','12','pieces_per_plate','480','ingredient_code','RM-BESAN','qty_per_plate','10','uom','KG'),
    jsonb_build_object('item_code','8', 'pieces_per_plate','',   'ingredient_code','RM-SUGAR','qty_per_plate','8', 'uom','KG'),
    jsonb_build_object('item_code','12','pieces_per_plate','',   'ingredient_code','RM-SUGAR','qty_per_plate','9', 'uom','KG'),
    jsonb_build_object('item_code','8', 'pieces_per_plate','',   'ingredient_code','RM-GHEE', 'qty_per_plate','500','uom','G'));

  -- 1. The dry run must count two recipes and write nothing at all.
  j := import_rows('recipes', rows, '{}'::jsonb, true);
  assert (j->>'total')::int = 2, format('32.1 expected 2 recipes, counted %s', j->>'total');
  assert (j->>'ok')::int = 2, format('32.1 dry run refused one: %s', j->'error_rows');
  assert (j->>'errors')::int = 0, format('32.1 %s', j->'error_rows');
  select count(*) into n from recipes where org_id = v_org;
  assert n = 0, format('32.1 the DRY RUN wrote %s recipes', n);
  select count(*) into n from recipe_ingredients;
  assert n = 0, format('32.1 the DRY RUN wrote %s ingredients', n);

  -- 2. Committed: two recipes, and the five scattered rows land in the right one.
  j := import_rows('recipes', rows, '{}'::jsonb, false);
  assert (j->>'errors')::int = 0, format('32.2 %s', j->'error_rows');
  select count(*) into n from recipes where org_id = v_org and is_active;
  assert n = 2, format('32.2 expected 2 recipes, got %s', n);

  select id into v_rec from recipes where org_id = v_org and item_id = v_mysore and is_active;
  select count(*) into n from recipe_ingredients where recipe_id = v_rec;
  assert n = 3, format('32.3 the rows for product 8 were split up: %s ingredients, expected 3', n);
  assert (select pieces_per_plate from recipes where id = v_rec) = 320,
    '32.3 pieces per plate did not carry from the first line to the rest of the group';
  assert (select name from recipes where id = v_rec) = 'MYSORE PAK PLATE', '32.3 the recipe name was dropped';

  select qty_per_plate, uom_id into v_qty, v_uom
    from recipe_ingredients where recipe_id = v_rec and ingredient_id = v_ghee;
  assert v_qty = 500, format('32.4 ghee quantity wrong: %s', v_qty);
  assert v_uom = v_g, '32.4 the unit on the line was not used';

  -- An ingredient with no unit falls back to its own stock unit rather than null.
  select id into v_rec from recipes where org_id = v_org and item_id = v_laddu and is_active;
  assert (select count(*) from recipe_ingredients where recipe_id = v_rec) = 2, '32.5 laddu recipe wrong size';

  -- 3. Re-importing replaces rather than piling up — one active recipe per product.
  j := import_rows('recipes', rows, '{}'::jsonb, false);
  assert (j->>'errors')::int = 0, format('32.6 %s', j->'error_rows');
  select count(*) into n from recipes where org_id = v_org and item_id = v_mysore and is_active;
  assert n = 1, format('32.6 a second run left %s active recipes on one product', n);
  select count(*) into n from recipe_ingredients ri join recipes r on r.id = ri.recipe_id
   where r.item_id = v_mysore and r.is_active;
  assert n = 3, format('32.6 ingredients piled up: %s', n);

  -- 4. One bad recipe must not take the good ones with it.
  j := import_rows('recipes', jsonb_build_array(
        jsonb_build_object('item_code','8','pieces_per_plate','320','ingredient_code','RM-BESAN','qty_per_plate','12','uom','KG'),
        jsonb_build_object('item_code','12','pieces_per_plate','480','ingredient_code','NO-SUCH','qty_per_plate','10','uom','KG')),
       '{}'::jsonb, true);
  assert (j->>'ok')::int = 1 and (j->>'errors')::int = 1,
    format('32.7 expected one good and one bad, got ok=%s errors=%s', j->>'ok', j->>'errors');
  v_err := j->'error_rows'->0->>'error';
  assert v_err like '%NO-SUCH%', format('32.7 does not name the missing ingredient: %s', v_err);
  assert (j->'error_rows'->0->>'row')::int = 2, format('32.7 blames the wrong row: %s', j->'error_rows'->0->>'row');

  -- 5. The refusals that protect the production figures, through save_recipe.
  j := import_rows('recipes', jsonb_build_array(
        jsonb_build_object('item_code','RM-BESAN','pieces_per_plate','10','ingredient_code','RM-SUGAR','qty_per_plate','1','uom','KG')),
       '{}'::jsonb, true);
  assert (j->>'errors')::int = 1, '32.8 a raw material was accepted as a product';
  assert j->'error_rows'->0->>'error' like '%not a finished good%',
    format('32.8 wrong reason: %s', j->'error_rows'->0->>'error');

  j := import_rows('recipes', jsonb_build_array(
        jsonb_build_object('item_code','8','pieces_per_plate','320','ingredient_code','12','qty_per_plate','1','uom','JAR')),
       '{}'::jsonb, true);
  assert (j->>'errors')::int = 1, '32.9 a finished good was accepted as an ingredient';

  j := import_rows('recipes', jsonb_build_array(
        jsonb_build_object('item_code','8','pieces_per_plate','','ingredient_code','RM-BESAN','qty_per_plate','12','uom','KG')),
       '{}'::jsonb, true);
  assert (j->>'errors')::int = 1, '32.10 a recipe with no pieces per plate was accepted';
  assert j->'error_rows'->0->>'error' like '%Pieces per plate%', '32.10 wrong reason';

  j := import_rows('recipes', jsonb_build_array(
        jsonb_build_object('item_code','8','pieces_per_plate','320','ingredient_code','RM-BESAN','qty_per_plate','12','uom','TONNE')),
       '{}'::jsonb, true);
  assert (j->>'errors')::int = 1, '32.11 an unknown unit was accepted';
  assert j->'error_rows'->0->>'error' like '%TONNE%', '32.11 does not name the unit';

  raise notice 'OK: recipe import — rows scattered through the file still make one recipe per product, pieces per plate carries from the first line, the dry run writes nothing, re-importing replaces instead of piling up, one bad recipe loses only itself and names what was wrong, and save_recipe still refuses a raw material as a product, a finished good as an ingredient, a missing plate size and an unknown unit';
end $$;

rollback;
