-- ============================================================
-- DB acceptance test: the next item code. Rolls back.
--
-- The shop wanted a running serial rather than a code somebody remembered was
-- free. The trap is that their master is not purely numeric — a repack is
-- written 27A, and that must never be counted or disturbed.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_code text;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;

  -- 1. An empty master starts at 1.
  assert next_item_code() = '1', format('24.1 expected 1, got %s', next_item_code());

  -- 2. It follows the highest number, not the count of rows.
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit)
  values (v_org, '8',  'HT. MYSOOR PAK(12) 32',  v_uom, 32, 12),
         (v_org, '12', 'BOONDI LADDU (12) 48',   v_uom, 48, 12);
  assert next_item_code() = '13', format('24.2 expected 13, got %s', next_item_code());

  -- 3. A repack keeps its letter and is ignored by the count — this is the one
  --    that matters. 27A must not read as 27, or the next code would be 28 and
  --    the real 27 would be skipped for ever.
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit)
  values (v_org, '27A', 'HT. MYSOOR PAK REPACK', v_uom, 32, 12),
         (v_org, '06A', 'BOONDI LADDU REPACK',   v_uom, 48, 12);
  assert next_item_code() = '13', format('24.3 a letter code moved the serial: %s', next_item_code());

  -- 4. The code it hands out is genuinely free, and taking it moves the serial on.
  v_code := next_item_code();
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit)
  values (v_org, v_code, 'KAJU KATLI', v_uom, 20, 1);
  assert next_item_code() = '14', format('24.4 expected 14 after taking 13, got %s', next_item_code());

  -- 5. The unique index is still the last word, whatever the screen suggests.
  begin
    insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit)
    values (v_org, '13', 'A SECOND 13', v_uom, 20, 1);
    raise exception '24.5 a duplicate item code was accepted';
  exception when unique_violation then null;
  end;

  -- 6. Inactive products still hold their number. Reusing the code of something
  --    that was merely stopped would put two different products on one code in
  --    the history.
  update items set is_active = false where item_code = '13' and org_id = v_org;
  assert next_item_code() = '14', format('24.6 an inactive product released its code: %s', next_item_code());

  raise notice 'OK: item code serial — the next code follows the highest all-digit code, ignores repack codes like 27A, keeps its number when a product is deactivated, and the unique index remains the last word';
end $$;

rollback;
