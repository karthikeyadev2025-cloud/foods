-- ============================================================
-- DB acceptance test: product photos and the printed rate card. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
revoke execute on function set_license_plan(uuid, text) from authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_sweets uuid; v_savoury uuid;
  v_mysoor uuid; v_laddu uuid; v_mixture uuid;
  r record; n int;
  uid_owner uuid := gen_random_uuid();
  uid_sales uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into sections (org_id, name, sort_order) values (v_org, 'SWEETS', 1) returning id into v_sweets;
  insert into sections (org_id, name, sort_order) values (v_org, 'SAVOURY', 2) returning id into v_savoury;
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, uid_sales, 'Sales', 'sales_exec');

  insert into items (org_id, item_code, name, section_id, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '8', 'MYSOOR PAK', v_sweets, v_uom, v_pack, 32, 12, 42) returning id into v_mysoor;
  insert into items (org_id, item_code, name, section_id, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '9', 'LADDU', v_sweets, v_uom, v_pack, 24, 10, 38) returning id into v_laddu;
  insert into items (org_id, item_code, name, section_id, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
    values (v_org, '40', 'MIXTURE', v_savoury, v_uom, v_pack, 20, 1, 30) returning id into v_mixture;

  -- ===== a photo is just a column on the item; anyone who may edit items sets it =====
  update items set image_url = 'https://x.supabase.co/storage/v1/object/public/products/' || v_org || '/8.jpg' where id = v_mysoor;
  update items set image_url = 'https://x.supabase.co/storage/v1/object/public/products/' || v_org || '/9.jpg' where id = v_laddu;

  -- ===== the whole card, in section order then name =====
  select count(*) into n from catalogue_items(); assert n = 3, format('every active item, found %s', n);
  select item_code, name, section_name, pack, unit_rate, box_rate, image_url into r
    from catalogue_items() limit 1;
  assert r.section_name = 'SWEETS' and r.name = 'LADDU', format('section order first, then name: %s', to_jsonb(r));
  assert r.pack = 'JAR' and r.unit_rate = 38, format('pack and rate carried %s', to_jsonb(r));
  -- box_rate is generated from unit_rate x units_per_box, so the card shows both
  assert r.box_rate = 38 * 24, format('box rate %s', r.box_rate);

  -- ===== one section =====
  select count(*) into n from catalogue_items(v_savoury); assert n = 1, format('savoury alone, found %s', n);
  select name into r from catalogue_items(v_savoury); assert r.name = 'MIXTURE';

  -- ===== a hand-picked list, in any order given =====
  select count(*) into n from catalogue_items(null, array[v_mixture, v_mysoor]);
  assert n = 2, format('two picked, found %s', n);
  select name into r from catalogue_items(null, array[v_mixture, v_mysoor]) limit 1;
  assert r.name = 'MYSOOR PAK', 'still ordered by section, not by the order they were given';

  -- ===== only the ones with a photo, so the card is not full of blanks =====
  select count(*) into n from catalogue_items(null, null, true); assert n = 2, format('with photo, found %s', n);
  select count(*) into n from catalogue_items(v_savoury, null, true); assert n = 0, 'savoury has no photo yet';

  -- ===== an inactive item never appears on a card =====
  update items set is_active = false where id = v_laddu;
  select count(*) into n from catalogue_items(); assert n = 2, format('inactive dropped, found %s', n);
  update items set is_active = true where id = v_laddu;

  -- ===== the photo is core, so it survives the step down to Starter =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  perform set_license_plan(v_org, 'starter');
  perform set_config('request.jwt.claim.sub', uid_owner::text, true); set local role authenticated;
  select count(*) into n from catalogue_items(); assert n = 3, format('Starter still prints a rate card, found %s', n);
  select image_url into r from catalogue_items(null, array[v_mysoor]);
  assert r.image_url like '%/products/%', format('and still has the photo %s', to_jsonb(r));

  -- ===== a role with no items right cannot read one =====
  perform set_config('request.jwt.claim.sub', uid_sales::text, true);
  select count(*) into n from catalogue_items(); assert n = 3, 'a sales exec may see items, so may print a card';
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  update role_permissions set can_view = false where org_id = v_org and role = 'sales_exec' and module = 'items';
  perform set_config('request.jwt.claim.sub', uid_sales::text, true); set local role authenticated;
  begin
    perform catalogue_items();
    assert false, 'without the Items right there is no card';
  exception when others then null; end;

  reset role;
  raise notice 'OK: product images — a photo is a column on the item, the rate card reads by section / picked list / photo-only, keeps section then name order, drops inactive items, carries pack and both rates, survives the drop to Starter because it is core, and needs the Items right to read';
end $$;

rollback;
