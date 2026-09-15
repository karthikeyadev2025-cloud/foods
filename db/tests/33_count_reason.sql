-- ============================================================
-- DB acceptance test: opening a stock count says which nothing. Rolls back.
--
-- The count sheet is built from ACTIVE FINISHED GOODS in the chosen section.
-- Three different emptinesses land on the same dead end and each needs a
-- different thing done about it, so each has to name itself — the version that
-- said only "No items to count" sent somebody looking for lost products when
-- the real answer was the section dropdown.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
grant all on all sequences in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_loc uuid; v_laddu uuid; v_empty uuid; v_item uuid; v_raw uuid;
  v_id uuid; v_msg text; n bigint;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org,'JAR','Jar','unit') returning id into v_uom;
  insert into stock_locations (org_id, name) values (v_org,'Godown') returning id into v_loc;
  insert into sections (org_id, code, name) values (v_org,'S-10','RAMA KRISHNA MESTRI') returning id into v_laddu;
  insert into sections (org_id, code, name) values (v_org,'S-99','NEW SECTION') returning id into v_empty;

  -- 1. No products at all: say so, and say where products come from.
  begin
    perform open_stock_count(v_loc, current_date);
    raise exception '33.1 a count opened with no products at all';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%no products yet%', format('33.1 wrong reason: %s', v_msg);
    assert v_msg like '%Import%', format('33.1 does not say what to do: %s', v_msg);
  end;

  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, section_id, type)
    values (v_org,'8','HT. MYSOOR PAK(12) 32', v_uom, 32, 12, v_laddu, 'finished_good') returning id into v_item;
  -- A raw material must not keep a count alive: the shop counts what it sells.
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, type)
    values (v_org,'RM-BESAN','BESAN FLOUR', v_uom, 1, 1, 'raw_material') returning id into v_raw;

  -- 2. THE ONE FROM THE REAL SCREEN. Products exist, but not in the section
  --    chosen in the dialog — and the refusal has to name that section, or the
  --    answer looks like the system has lost two hundred products.
  begin
    perform open_stock_count(v_loc, current_date, v_empty);
    raise exception '33.2 a count opened on a section with no products';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%NEW SECTION%', format('33.2 does not name the section: %s', v_msg);
    assert v_msg like '%All sections%', format('33.2 does not offer the way out: %s', v_msg);
  end;

  -- 3. With no section, or the right one, it opens and holds only the finished good.
  v_id := open_stock_count(v_loc, current_date);
  select count(*) into n from stock_count_items where count_id = v_id;
  assert n = 1, format('33.3 expected 1 line, got %s — a raw material got onto the sheet', n);
  assert exists (select 1 from stock_count_items where count_id = v_id and item_id = v_item), '33.3 wrong item';
  perform cancel_stock_count(v_id);

  v_id := open_stock_count(v_loc, current_date, v_laddu);
  assert (select count(*) from stock_count_items where count_id = v_id) = 1, '33.4 the section count is empty';
  perform cancel_stock_count(v_id);

  -- 4. Every product inactive is its own answer, not the same one.
  update items set is_active = false where org_id = v_org;
  begin
    perform open_stock_count(v_loc, current_date);
    raise exception '33.5 a count opened with every product inactive';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%inactive%', format('33.5 wrong reason: %s', v_msg);
    assert v_msg not like '%no products yet%', format('33.5 confuses inactive with absent: %s', v_msg);
  end;

  raise notice 'OK: stock count refusals — no products, a section with none in it (named, with the way out), and everything inactive each say which nothing it is; a raw material never reaches the sheet, and a real section still opens';
end $$;

rollback;
