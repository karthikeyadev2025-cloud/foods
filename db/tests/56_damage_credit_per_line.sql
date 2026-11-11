-- ============================================================
-- DB acceptance test: the damage credit is per line, not per shop.
--
-- "Remove the existing fixed 50% discount applied to damaged items… allow
-- users to manually enter the discount based on the condition of the damaged
-- item." A return often carries several items in different states, so the
-- figure has to follow the item, and a return typed the old way must not move.
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
  v_org uuid; v_jar uuid; v_loc uuid; v_cust uuid; v_a uuid; v_b uuid;
  v_ret uuid; q numeric; n int; v_msg text; v_header jsonb;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  -- the shop's usual figure
  update orgs set breakage_recovery_pct = 50 where id = v_org;

  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'RAVI STORES') returning id into v_cust;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'8','MYSOOR PAK', v_jar, 10, 1, 10) returning id into v_a;
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org,'9','CHEKKALU', v_jar, 10, 1, 10) returning id into v_b;

  v_header := jsonb_build_object('customer_id', v_cust, 'kind', 'damage_return',
                                 'return_date', current_date::text, 'location_id', v_loc);

  -- ===== 56.1 typed the old way, nothing changes =====
  -- 2 boxes x 10 jars x 10 = 200 billed, half of it is 100
  v_ret := save_sales_return(v_header, jsonb_build_array(
    jsonb_build_object('item_id', v_a, 'boxes', 2, 'rate', 10)));
  select total into q from sales_returns where id = v_ret;
  assert q = 100, format('56.1 with no percentage typed it must still be the shop''s 50%%: %s', q);
  select recovery_pct into q from sales_return_items where return_id = v_ret;
  assert q = 50, format('56.1 the line should record the figure it used, has %s', q);

  -- ===== 56.2 two items on one return, in different states =====
  v_ret := save_sales_return(v_header, jsonb_build_array(
    -- a crushed box: nothing is saleable
    jsonb_build_object('item_id', v_a, 'boxes', 2, 'rate', 10, 'recovery_pct', 100),
    -- a cracked lid: most of it is fine
    jsonb_build_object('item_id', v_b, 'boxes', 2, 'rate', 10, 'recovery_pct', 25)));
  select total into q from sales_returns where id = v_ret;
  assert q = 200 + 50, format('56.2 200 at 100%% plus 200 at 25%% is 250, got %s', q);
  select amount into q from sales_return_items ri where ri.return_id = v_ret and ri.item_id = v_a;
  assert q = 200, format('56.2 the crushed box credits in full: %s', q);
  select amount into q from sales_return_items ri where ri.return_id = v_ret and ri.item_id = v_b;
  assert q = 50, format('56.2 the cracked lid credits a quarter: %s', q);

  -- ===== 56.3 nothing at all is a credit of nothing, not a fall-back =====
  v_ret := save_sales_return(v_header, jsonb_build_array(
    jsonb_build_object('item_id', v_a, 'boxes', 2, 'rate', 10, 'recovery_pct', 0)));
  select total into q from sales_returns where id = v_ret;
  assert q = 0, format('56.3 zero per cent must mean zero, not the shop default: %s', q);

  -- ===== 56.4 a figure that cannot be right is refused by name =====
  begin
    perform save_sales_return(v_header, jsonb_build_array(
      jsonb_build_object('item_id', v_a, 'boxes', 1, 'rate', 10, 'recovery_pct', 140)));
    raise exception '56.4 a credit of 140 per cent was accepted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%between 0 and 100%', format('56.4 wrong reason: %s', v_msg);
  end;

  -- ===== 56.5 changing ONLY the percentage is a change =====
  -- db/61 skips a save that changes nothing; it must not skip this one.
  v_ret := save_sales_return(v_header, jsonb_build_array(
    jsonb_build_object('item_id', v_a, 'boxes', 2, 'rate', 10, 'recovery_pct', 50)));
  select total into q from sales_returns where id = v_ret;
  assert q = 100, '56.5 starts at half';
  perform save_sales_return(v_header || jsonb_build_object('id', v_ret), jsonb_build_array(
    jsonb_build_object('item_id', v_a, 'boxes', 2, 'rate', 10, 'recovery_pct', 75)));
  select total into q from sales_returns where id = v_ret;
  assert q = 150, format('56.5 raising the credit to 75%% must take: %s', q);
  -- and saving the same thing again still writes nothing
  select count(*) into n from sales_return_items where return_id = v_ret;
  perform save_sales_return(v_header || jsonb_build_object('id', v_ret), jsonb_build_array(
    jsonb_build_object('item_id', v_a, 'boxes', 2, 'rate', 10, 'recovery_pct', 75)));
  assert (select count(*) from sales_return_items where return_id = v_ret) = n,
    '56.5 re-saving the same return must still write nothing';

  -- ===== 56.6 a fresh return is untouched by any of this =====
  v_ret := save_sales_return(
    v_header || jsonb_build_object('kind', 'fresh_return'),
    jsonb_build_array(jsonb_build_object('item_id', v_a, 'boxes', 2, 'rate', 10, 'recovery_pct', 10)));
  select total into q from sales_returns where id = v_ret;
  assert q = 200, format('56.6 a fresh return is credited in full whatever is typed: %s', q);
  select recovery_pct into q from sales_return_items where return_id = v_ret;
  assert q is null, '56.6 and carries no damage percentage';

  raise notice 'OK: a damage return credits per line — a crushed box at 100%% and a cracked lid at 25%% on the same return — while a return typed the old way still takes the shop''s own figure and reads exactly as before; zero means zero, a figure outside 0 to 100 is refused by name, changing only the percentage counts as a change where re-saving the same return still writes nothing, and a fresh return is untouched';
end $$;

rollback;
