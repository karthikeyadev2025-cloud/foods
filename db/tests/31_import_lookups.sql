-- ============================================================
-- DB acceptance test: an unknown pack type or section no longer throws the
-- whole product away. Rolls back.
--
-- The screen this comes from read: 250 rows, 250 errors, every one of them
-- 'Unknown pack type "BOX"'. Packing, codes and rates were all correct. What
-- stopped the lot was a label.
--
-- The dry-run assertion is the one that matters. Ticking the box on the CHECK
-- step must not leave pack types behind on a database where nothing was
-- imported — otherwise looking becomes doing, which is the one promise the
-- check step makes.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; j jsonb; n bigint; v_err text;
  uid_owner uuid := gen_random_uuid();
  -- Four lines out of the real report: two cartons spelled differently, one
  -- section the master has never heard of.
  v_rows jsonb := jsonb_build_array(
    jsonb_build_object('item_code','1','name','5/- BOONDI LADDU (8)','units_per_box','8','pieces_per_unit','8',
                       'pack_type','BOX','section_code','RAMA KRISHANA','mrp_per_piece','5'),
    jsonb_build_object('item_code','2','name','5/- BOONDI LADDU (12) 48','units_per_box','48','pieces_per_unit','12',
                       'pack_type','TRY','section_code','RAMA KRISHANA','mrp_per_piece','5'),
    jsonb_build_object('item_code','3','name','5/- BOONDI LADDU (12)21','units_per_box','21','pieces_per_unit','12',
                       'pack_type','Box','section_code','RAMA KRISHANA','mrp_per_piece','5'),
    jsonb_build_object('item_code','4','name','5/- ANNAMAYYA LADDU (8)','units_per_box','8','pieces_per_unit','8',
                       'pack_type','BOX','section_code','CHINNA MASTRY','mrp_per_piece','5'));
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR');
  insert into sections (org_id, code, name) values (v_org, 'S-1', 'CHINNA MASTRY');

  -- 1. Left alone, it still refuses — and now says what to do about it.
  j := import_rows('items', v_rows, '{}'::jsonb, true);
  assert (j->>'errors')::int = 4, format('31.1 expected all four refused, got %s', j->>'errors');
  v_err := j->'error_rows'->0->>'error';
  assert v_err like '%Unknown pack type%', format('31.1 wrong reason: %s', v_err);
  assert v_err like '%Create missing pack types and sections%',
    format('31.1 the refusal does not mention the way out: %s', v_err);

  -- 2. THE ONE THAT MATTERS. Ticked, the dry run says they would all import —
  --    and creates nothing, because looking is not doing.
  j := import_rows('items', v_rows, jsonb_build_object('create_lookups', true), true);
  assert (j->>'errors')::int = 0, format('31.2 dry run still refused: %s', j->'error_rows');
  assert (j->>'ok')::int = 4, format('31.2 expected 4 would import, got %s', j->>'ok');
  select count(*) into n from pack_types where org_id = v_org;
  assert n = 1, format('31.2 the DRY RUN created pack types: %s exist, expected only JAR', n);
  select count(*) into n from sections where org_id = v_org;
  assert n = 1, format('31.2 the DRY RUN created sections: %s exist, expected only CHINNA MASTRY', n);
  select count(*) into n from items where org_id = v_org;
  assert n = 0, format('31.2 the DRY RUN created items: %s', n);

  -- 3. Committed, the four products land and the labels are created once each.
  j := import_rows('items', v_rows, jsonb_build_object('create_lookups', true), false);
  assert (j->>'ok')::int = 4, format('31.3 expected 4 imported, got %s — %s', j->>'ok', j->'error_rows');
  select count(*) into n from items where org_id = v_org;
  assert n = 4, format('31.3 expected 4 items, got %s', n);

  -- BOX, Box and BOZ are the same carton to normalize_code, so 'Box' on row 3
  -- must find what row 1 created rather than make a second one.
  select count(*) into n from pack_types where org_id = v_org;
  assert n = 3, format('31.3 expected JAR + BOX + TRY = 3 pack types, got %s', n);
  assert exists (select 1 from pack_types where org_id = v_org and code = 'BOX'), '31.3 BOX was not created';
  assert exists (select 1 from pack_types where org_id = v_org and code = 'TRY'), '31.3 TRY was not created';

  -- The new section is created by NAME with no code. A code invented here would
  -- collide with the real one the day it arrives.
  select count(*) into n from sections where org_id = v_org;
  assert n = 2, format('31.3 expected 2 sections, got %s', n);
  assert exists (select 1 from sections where org_id = v_org and name = 'RAMA KRISHANA' and code is null),
    '31.3 the new section was not created by name, or was given an invented code';
  assert (select sort_order from sections where org_id = v_org and name = 'RAMA KRISHANA') > 0,
    '31.3 the new section did not go to the end of the print order';

  -- The existing section was matched, not duplicated.
  assert (select section_id from items where org_id = v_org and item_code = '4')
       = (select id from sections where org_id = v_org and code = 'S-1'),
    '31.4 an existing section was not reused';

  -- 4. Re-importing the same file changes nothing and creates nothing more.
  j := import_rows('items', v_rows, jsonb_build_object('create_lookups', true), false);
  assert (j->>'errors')::int = 0, format('31.5 second run had errors: %s', j->'error_rows');
  select count(*) into n from pack_types where org_id = v_org;
  assert n = 3, format('31.5 a second run made more pack types: %s', n);
  select count(*) into n from items where org_id = v_org;
  assert n = 4, format('31.5 a second run made more items: %s', n);

  raise notice 'OK: import lookups — an unknown pack type or section refuses with the way out named; ticked, the dry run passes all four and writes nothing at all; committed, BOX and TRY are created once each with Box folded into BOX, the new section is created by name with no code and goes last, the existing section is reused, and a second run adds nothing';
end $$;

rollback;
