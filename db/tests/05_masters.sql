-- ============================================================
-- DB acceptance test: T1 masters.
-- Rolls back at the end.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_item uuid; v_veh uuid; v_locv uuid;
  s1 uuid; s2 uuid; s3 uuid; n int; t text; b boolean;
  uid_owner uuid := gen_random_uuid();
  uid_store uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;

  -- 1. units_per_box has no default any more ------------------------
  begin
    insert into items (org_id, item_code, name, base_uom_id) values (v_org, 'X', 'no packing', v_uom);
    raise exception 'an item without units_per_box must be rejected';
  exception when not_null_violation then null;
  end;
  begin
    insert into items (org_id, item_code, name, base_uom_id, units_per_box) values (v_org, 'X', 'zero packing', v_uom, 0);
    raise exception 'units_per_box = 0 must be rejected';
  exception when check_violation then null;
  end;

  -- 2. Item list view: packing lock flag flips with the first ledger row
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '2', '5/- BOONDI LADDU (12) 48', v_uom, v_pack, 48, 12, 40) returning id into v_item;
  select has_stock_movement, pack_code into b, t from v_item_list where id = v_item;
  assert b = false and t = 'JAR', 'new item: no stock movement, pack code joined';
  select box_rate into n from v_item_list where id = v_item;
  assert n = 40 * 48, format('box_rate should be computed: %s', n);
  update items set units_per_box = 24 where id = v_item;          -- allowed: no stock yet
  update items set units_per_box = 48 where id = v_item;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, qty_base) values (v_org, v_item, v_loc, 'opening', 96);
  select has_stock_movement, stock_base into b, n from v_item_list where id = v_item;
  assert b = true and n = 96, 'after a ledger row the item is locked and stock_base sums';
  begin
    update items set units_per_box = 24 where id = v_item;
    raise exception 'packing lock did not fire';
  exception when others then
    if sqlerrm not like 'Packing is locked%' then raise; end if;
  end;

  -- 3. Sections reorder ----------------------------------------------
  insert into sections (org_id, code, name, sort_order) values (v_org, 'S-1', 'A', 1) returning id into s1;
  insert into sections (org_id, code, name, sort_order) values (v_org, 'S-2', 'B', 2) returning id into s2;
  insert into sections (org_id, code, name, sort_order) values (v_org, 'S-3', 'C', 3) returning id into s3;
  perform reorder_sections(array[s3, s1, s2]);
  select string_agg(name, '' order by sort_order) into t from sections where org_id = v_org;
  assert t = 'CAB', format('reorder: expected CAB, got %s', t);
  begin
    perform reorder_sections(array[s1, gen_random_uuid()]);
    raise exception 'reorder must reject foreign ids';
  exception when others then
    if sqlerrm not like '%your organisation%' then raise; end if;
  end;

  -- 4. Customers: mobile1 unique per org ------------------------------
  insert into customers (org_id, name, mobile1) values (v_org, 'A', '9849686746');
  begin
    insert into customers (org_id, name, mobile1) values (v_org, 'B', '9849686746');
    raise exception 'duplicate mobile1 must be rejected';
  exception when unique_violation then null;
  end;
  insert into customers (org_id, name) values (v_org, 'no mobile 1');
  insert into customers (org_id, name) values (v_org, 'no mobile 2');   -- nulls are fine
  select count(*) into n from v_customer_list where org_id = v_org; assert n = 3;

  -- 5. Vehicle creates its stock location, even for a store keeper ----
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_store, 'Store', 'store_keeper');
  perform set_config('request.jwt.claim.sub', uid_store::text, true);
  assert can_edit('vehicles') and not can_edit('setup'), 'store keeper: vehicles yes, setup no';
  insert into vehicles (org_id, vehicle_number, owner_name) values (v_org, 'ap07 ab 1234', 'Owner')
    returning id, location_id into v_veh, v_locv;
  assert v_locv is not null, 'vehicle should get a location';
  select name into t from stock_locations where id = v_locv and kind = 'vehicle';
  assert t = 'VAN AP07 AB 1234', format('location name: %s', t);
  select location_name into t from v_vehicle_list where id = v_veh;
  assert t = 'VAN AP07 AB 1234', 'vehicle list joins its location';
  update vehicles set vehicle_number = 'AP07AB9999' where id = v_veh;
  select name into t from stock_locations where id = v_locv;
  assert t = 'VAN AP07AB9999', format('rename should follow: %s', t);
  update vehicles set is_active = false where id = v_veh;
  select is_active into b from stock_locations where id = v_locv;
  assert b = false, 'deactivating a vehicle deactivates its location';

  reset role;
  raise notice 'OK: masters — no default packing, packing lock flag, reorder, unique mobile, vehicle ↔ location';
end $$;

rollback;
