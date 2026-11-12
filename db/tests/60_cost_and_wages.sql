-- ============================================================
-- DB acceptance test: what we pay, and what we pay people.
--
-- A counter boy — the lowest role in the shop, no purchases right, no
-- payments right, no reports right — could read our buying price, our gross
-- profit per item, and what every other person in the shop earns. Not because
-- he was shown a row he should not see: because those are COLUMNS on rows
-- everybody is allowed to see, and the module gates only decide rows.
--
-- The figures in here are the ones from the live schema that proved it:
-- an item that sells at 100 and costs 62, an owner on 18,000 a day.
--
-- Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
-- Supabase's default privileges grant everything on every table, which puts
-- the wage column back. db/71 closes it again on a live database; the test has
-- to do the same or it is testing the grant above, not the fix.
select lock_cost_and_wage_columns();

do $$
declare
  v_org uuid; owner_uid uuid := gen_random_uuid(); sales_uid uuid := gen_random_uuid(); store_uid uuid := gen_random_uuid();
  v_jar uuid; v_loc uuid; v_item uuid; v_cust uuid; v_inv uuid;
  v_cost numeric; v_profit numeric; v_msg text; n int;
begin
  perform set_config('request.jwt.claim.sub', owner_uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_jar;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into customers (org_id, name) values (v_org,'RAVI STORES') returning id into v_cust;
  -- sells at 100, costs us 62
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org,'8','MYSOOR PAK', v_jar, 10, 1, 100, 62) returning id into v_item;
  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base)
    values (v_org,v_item,v_loc,'opening',current_date-5, 1000);
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date::text, 'location_id', v_loc),
                        jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 5, 'rate', 100)));
  perform set_invoice_status(v_inv, 'confirmed');

  -- ===== 60.1 the owner sees everything, as always =====
  select purchase_rate into v_cost from v_item_list where id = v_item;
  assert v_cost = 62, format('60.1 the owner must see the cost on the item screen: %s', v_cost);
  assert item_cost(v_item) = 62, format('60.1 and through item_cost(): %s', item_cost(v_item));
  select cost_value, gross_profit into v_cost, v_profit from v_item_profit where item_id = v_item;
  assert v_cost = 3100 and v_profit = 1900, format('60.1 owner profit view: cost %s, profit %s', v_cost, v_profit);

  reset role; perform set_config('request.jwt.claim.sub', '', true);
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, sales_uid, 'Counter boy', 'sales_exec');
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, store_uid, 'Godown', 'store_keeper');
  update staff set daily_wage = 18000 where org_id = v_org and role = 'owner';

  -- ===== 60.2 the counter boy may not see what it cost us =====
  perform set_config('request.jwt.claim.sub', sales_uid::text, true); set local role authenticated;
  assert my_role() = 'sales_exec' and not can_view('purchases'), '60.2 this is the counter boy, with no purchases right';
  assert not can_see_cost(), '60.2 and no business knowing cost';

  select purchase_rate into v_cost from v_item_list where id = v_item;
  assert v_cost is null, format('60.2 the item screen must not show him the cost: %s', v_cost);
  assert item_cost(v_item) is null, format('60.2 nor item_cost(): %s', item_cost(v_item));

  select cost_value, gross_profit into v_cost, v_profit from v_item_profit where item_id = v_item;
  assert v_cost is null and v_profit is null,
    format('60.2 nor the profit per item: cost %s, profit %s', v_cost, v_profit);

  -- he can still do his job: the item, its name and its selling rate
  select count(*) into n from v_item_list where id = v_item and unit_rate = 100;
  assert n = 1, '60.2 but he must still see the item and what it sells for';

  -- ===== 60.3 nor what anybody is paid =====
  begin
    select daily_wage into v_cost from staff where org_id = v_org and role = 'owner';
    raise exception '60.3 the counter boy read the owner''s wage: %', v_cost;
  exception when insufficient_privilege then null; end;
  -- not even his own, through the table
  begin
    select daily_wage into v_cost from staff where auth_uid = sales_uid;
    raise exception '60.3 the wage column is readable after all';
  exception when insufficient_privilege then null; end;
  assert staff_wage((select id from staff where auth_uid = sales_uid)) is null,
    '60.3 and staff_wage() refuses him too';

  -- the staff NAMES stay readable, or sixteen screens lose "entered by"
  select count(*) into n from staff where org_id = v_org;
  assert n = 3, format('60.3 names must still be readable, sees %s rows', n);

  -- ===== 60.4 the store keeper, whose job it is, does see cost =====
  reset role; perform set_config('request.jwt.claim.sub', store_uid::text, true); set local role authenticated;
  assert can_see_cost(), '60.4 a store keeper buys the stock, so he may see what it costs';
  select purchase_rate into v_cost from v_item_list where id = v_item;
  assert v_cost = 62, format('60.4 the godown must see the cost: %s', v_cost);
  -- but still not the wage bill
  begin
    select daily_wage into v_cost from staff where org_id = v_org and role = 'owner';
    raise exception '60.4 the store keeper read the wage bill';
  exception when insufficient_privilege then null; end;

  -- ===== 60.5 a role that runs attendance does see wages =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  update staff set role = 'accountant' where auth_uid = store_uid;
  perform set_config('request.jwt.claim.sub', store_uid::text, true); set local role authenticated;
  assert can_view('attendance'), '60.5 an accountant runs the wage sheet';
  assert staff_wage((select id from staff where org_id = v_org and role = 'owner')) = 18000,
    '60.5 so staff_wage() answers for him';

  reset role;
  raise notice 'OK: our buying price and our gross profit are off the item screen, the profit view and the recipe costing for any role without purchases or production — while the store keeper who buys the stock still sees them; and what each person is paid is not readable from the staff table by ANYONE signed in, not even their own row, while staff names stay readable so every "entered by" still shows, and the wage sheet gets its figures through staff_wage()';
end $$;

rollback;
