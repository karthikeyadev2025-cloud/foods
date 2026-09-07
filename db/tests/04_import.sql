-- ============================================================
-- DB acceptance test: T0.5 importer + T0.6 the client's real data.
-- Loads seed/*.csv through import_rows() exactly as the screen does,
-- as the `authenticated` owner. Run from the repo root. Rolls back.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/04_import.sql
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

create temp table t_sections (code text, name text, sort_order text);
\copy t_sections from 'seed/sections.csv' csv header
create temp table t_items (item_code text, pack_type text, name text, units_per_box text, pieces_per_unit text, mrp_per_piece text, section_code text);
\copy t_items from 'seed/items.csv' csv header
create temp table t_unmatched (item_code text, pack_type text, name text, units_per_box text, pieces_per_unit text, mrp_per_piece text, section_code text, opening_boxes text);
\copy t_unmatched from 'seed/unmatched_items.csv' csv header
create temp table t_stock (item_code text, section_code text, opening_boxes text);
\copy t_stock from 'seed/opening_stock.csv' csv header
grant select on t_sections, t_items, t_unmatched, t_stock to authenticated;

do $$
declare
  v_org uuid; v_loc uuid; res jsonb; n int; n2 int;
  uid_owner uuid := gen_random_uuid();
  n_unmatched_with_packing int; n_unmatched_without int;
  n_stock_rows int; n_stock_codes_known int; n_neg_expected int;
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');

  -- What the wizard's "add standard" buttons create --------------------
  insert into uoms (org_id, code, name, basis, weight_g, sort_order) values
    (v_org,'BOX','Box','box',null,1), (v_org,'JAR','Jar','unit',null,2), (v_org,'PACK','Pack','unit',null,3),
    (v_org,'LB','L.B','unit',null,4), (v_org,'TRY','Tray','unit',null,5), (v_org,'PC','Piece','piece',null,6),
    (v_org,'KG','Kilogram','weight',1000,7), (v_org,'GM','Gram','weight',1,8);
  insert into pack_types (org_id, code, name, sort_order) values
    (v_org,'JAR','Jar',1), (v_org,'PACK','Pack',2), (v_org,'L.B','L.B',3), (v_org,'KG','Loose (kg)',4),
    (v_org,'TRY','Tray',5), (v_org,'BOX','Box',6);
  insert into stock_locations (org_id, name) values (v_org, 'Main godown') returning id into v_loc;

  -- 1. Sections -----------------------------------------------------------
  res := import_rows('sections', (select jsonb_agg(to_jsonb(t)) from t_sections t), '{}', true);
  assert (res->>'errors')::int = 0, format('sections dry run errors: %s', res->'error_rows');
  select count(*) into n from sections; assert n = 0, 'dry run must write nothing';

  res := import_rows('sections', (select jsonb_agg(to_jsonb(t)) from t_sections t), '{}', false);
  assert (res->>'ok')::int = 15, format('expected 15 sections, got %s', res);
  select count(*) into n from sections where org_id = v_org; assert n = 15;
  select count(*) into n from sections where code is null; assert n = 3, 'OTHERS ×2 and R.K.BAKERY have no code';

  -- 2. Items from the price list ---------------------------------------
  res := import_rows('items', (select jsonb_agg(to_jsonb(t)) from t_items t), '{}', false);
  assert (res->>'errors')::int = 0, format('items errors: %s', res->'error_rows');
  assert (res->>'ok')::int = 166, format('expected 166 items, got %s', res->>'ok');
  select count(distinct units_per_box) into n from items where org_id = v_org;
  assert n >= 12, format('units_per_box should vary widely (6…60), only %s distinct', n);
  select count(*) into n from items where org_id = v_org and units_per_box = 8;
  select count(*) into n2 from items where org_id = v_org;
  assert n < n2, 'not everything is 8 per box';
  select count(*) into n from items where org_id = v_org and item_code in ('27A','06A','83B','200A');
  assert n >= 2, 'text item codes like 27A / 83B must survive as text';
  select count(*) into n from items i join pack_types p on p.id = i.pack_type_id
   where i.org_id = v_org and p.code = 'L.B';
  assert n > 0, 'LB in the CSV must map to the L.B pack type';
  select count(*) into n from items where org_id = v_org and section_id is null;
  assert n < 40, format('too many items without a section (%s)', n);

  -- Re-import is idempotent
  res := import_rows('items', (select jsonb_agg(to_jsonb(t)) from t_items t), '{}', false);
  select count(*) into n from items where org_id = v_org; assert n = 166, 're-import must not duplicate';

  -- 3. The 87 stock-report-only codes: those whose name encodes the packing
  --    load; the rest are error rows for the client (needs units_per_box).
  -- \copy reads an empty CSV field as NULL, so test for both.
  select count(*) filter (where nullif(units_per_box, '') is not null),
         count(*) filter (where nullif(units_per_box, '') is null)
    into n_unmatched_with_packing, n_unmatched_without from t_unmatched;
  res := import_rows('items', (select jsonb_agg(to_jsonb(t)) from t_unmatched t), '{}', false);
  assert (res->>'ok')::int = n_unmatched_with_packing,
    format('unmatched with packing: expected %s ok, got %s', n_unmatched_with_packing, res->>'ok');
  assert (res->>'errors')::int = n_unmatched_without,
    format('unmatched without packing: expected %s errors, got %s', n_unmatched_without, res->>'errors');
  assert res->'error_rows'->0->>'error' like '%units_per_box%', 'error must say what is missing';

  -- 4. Opening stock, in boxes, converted per item ----------------------
  -- A code that repeats in the sheet is refused (both rows), so "known" here
  -- means: in the item master AND listed exactly once.
  select count(*) into n_stock_rows from t_stock;
  select count(*) into n_stock_codes_known from t_stock s
   where exists (select 1 from items i where i.org_id = v_org and i.item_code = normalize_item_code(s.item_code))
     and (select count(*) from t_stock s2 where normalize_item_code(s2.item_code) = normalize_item_code(s.item_code)) = 1;
  res := import_rows('opening_stock', (select jsonb_agg(to_jsonb(t)) from t_stock t),
                     jsonb_build_object('location_id', v_loc, 'txn_date', '2026-09-06'), false);
  assert (res->>'errors')::int = n_stock_rows - n_stock_codes_known,
    format('opening errors should equal unknown codes (%s), got %s', n_stock_rows - n_stock_codes_known, res->>'errors');
  assert (res->>'ok')::int + (res->>'unchanged')::int = n_stock_codes_known, format('opening ok+unchanged: %s', res);

  -- Boxes were converted with the item's own packing, never 8
  select sum(sl.qty_base) into n from stock_ledger sl join items i on i.id = sl.item_id
   where i.org_id = v_org and i.item_code = '3';         -- 5/- BOONDI LADDU (12) 21 : 38 boxes
  assert n = 38 * 21, format('code 3: 38 boxes × 21 = %s, got %s', 38 * 21, n);

  -- Re-import: nothing changes, nothing duplicates
  select count(*) into n from stock_ledger where org_id = v_org;
  res := import_rows('opening_stock', (select jsonb_agg(to_jsonb(t)) from t_stock t),
                     jsonb_build_object('location_id', v_loc, 'txn_date', '2026-09-06'), false);
  assert (res->>'ok')::int = 0, format('second opening import must add nothing, got %s', res);
  select count(*) into n2 from stock_ledger where org_id = v_org;
  assert n2 = n, 'ledger row count must not change on re-import';

  -- A corrected figure posts an adjustment row, never an UPDATE
  res := import_rows('opening_stock', '[{"item_code":"3","opening_boxes":"40"}]',
                     jsonb_build_object('location_id', v_loc, 'txn_date', '2026-09-06'), false);
  assert (res->>'ok')::int = 1;
  select sum(qty_base), count(*) into n, n2 from stock_ledger sl join items i on i.id = sl.item_id
   where i.org_id = v_org and i.item_code = '3';
  assert n = 40 * 21 and n2 = 2, format('adjustment: expected %s over 2 rows, got %s over %s', 40 * 21, n, n2);

  -- 5. Closing stock report: grouped by section, negatives shown ---------
  select count(distinct section_name) into n from closing_stock_report(v_org, date '2026-09-06');
  assert n >= 15, format('report should carry all 15 sections, got %s', n);
  select count(*) into n_neg_expected from t_stock s
   where s.opening_boxes::numeric < 0
     and exists (select 1 from items i where i.org_id = v_org and i.item_code = normalize_item_code(s.item_code))
     and (select count(*) from t_stock s2 where normalize_item_code(s2.item_code) = normalize_item_code(s.item_code)) = 1;
  select count(*) into n from closing_stock_report(v_org, date '2026-09-06') where is_negative;
  assert n = n_neg_expected, format('negative rows must be shown, expected %s got %s', n_neg_expected, n);
  assert n >= 3, 'the client''s sheet has negative rows and they must survive';

  -- 6. Rates: update only --------------------------------------------------
  res := import_rows('rates', '[{"item_code":"8","unit_rate":"42"},{"item_code":"NOPE","unit_rate":"1"}]', '{}', false);
  assert (res->>'ok')::int = 1 and (res->>'errors')::int = 1, format('rates: %s', res);
  select unit_rate into n from items where org_id = v_org and item_code = '8'; assert n = 42;

  -- 7. Customers: idempotent on mobile1 -----------------------------------
  res := import_rows('customers',
    '[{"name":"P. SRINIVAS (MCL)","mobile1":"98496 86746","town":"MACHARLA","route":"Macherla"},
      {"name":"P. SRINIVAS","mobile1":"9849686746","town":"MACHARLA"},
      {"name":"No mobile"}]', '{}', false);
  assert (res->>'ok')::int = 2 and (res->>'errors')::int = 1, format('customers: %s', res);
  select count(*) into n from customers where org_id = v_org; assert n = 1, 'same mobile = same customer';
  select count(*) into n from routes where org_id = v_org and name = 'Macherla'; assert n = 1;

  -- Every commit is a job row
  select count(*) into n from import_jobs where org_id = v_org and status = 'committed';
  assert n >= 8, format('expected import_jobs rows, got %s', n);

  reset role;
  raise notice 'OK: seed loads through the importer — 15 sections, 166 + % items, % opening rows, % negative; re-import is a no-op',
    n_unmatched_with_packing, n_stock_codes_known, n_neg_expected;
end $$;

rollback;
