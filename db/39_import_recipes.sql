-- ============================================================
-- JYOTHI FOODS ERP — 39: RECIPES FROM A SPREADSHEET
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "Import recipe in excel not working" — it was never built. The importer had
-- five targets and recipes was not one of them, so there was nothing to fail.
--
-- Recipes are the first thing here whose rows are NOT independent records. A
-- recipe is a product plus everything that goes into it, so it arrives as one
-- row per ingredient with the product code repeated down the sheet, and the
-- rows for one product have to become one recipe.
--
-- Everything else in import_rows is unchanged, and the signature is the same,
-- so this replaces the function rather than adding a second one beside it.
-- ============================================================

create or replace function import_rows(
  p_target  text,
  p_rows    jsonb,
  p_options jsonb default '{}'::jsonb,
  p_dry_run boolean default true
) returns jsonb language plpgsql as $$
declare
  v_org     uuid := my_org_id();
  v_staff   uuid;
  r         jsonb;
  i         int := 0;
  n_ok      int := 0;
  n_err     int := 0;
  n_skip    int := 0;
  errors    jsonb := '[]'::jsonb;
  v_action  text;
  -- shared scratch
  v_code    text;
  v_name    text;
  v_id      uuid;
  v_num     numeric;
  v_txt     text;
  v_pack    uuid;
  v_uom     uuid;
  v_sec     uuid;
  v_route   uuid;
  v_loc     uuid;
  v_date    date;
  v_upb     integer;
  v_ppu     integer;
  v_qty     numeric;
  v_have    numeric;
  v_mobile  text;
  dups      jsonb := '{}'::jsonb;   -- opening_stock: code → [row numbers] when a code repeats in the file
  -- recipes: the only target whose rows are not independent of each other.
  grp       record;
  l         jsonb;
  v_lines   jsonb;
  v_ing     uuid;
  -- Off unless the person ticked the box. Creating master rows from a
  -- spreadsheet is how "BOX", "Box" and "BOZ" become three pack types, so it
  -- stays a decision somebody makes, not a default.
  v_make    boolean := coalesce((p_options->>'create_lookups')::boolean, false);
begin
  if v_org is null then
    raise exception 'Not signed in to an organisation';
  end if;
  if p_target not in ('sections','items','customers','opening_stock','rates','recipes') then
    raise exception 'Unknown import target %', p_target;
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a JSON array';
  end if;

  v_staff := my_staff_id();

  -- ================================================================
  -- RECIPES. Handled here and returned, not in the loop below, because this is
  -- the one target where a row is not a record. A recipe is a product and the
  -- list of things that go into it, so the sheet holds ONE ROW PER INGREDIENT
  -- with the product code repeated:
  --
  --   Product code | Pieces per plate | Ingredient code | Qty per plate | Unit
  --   8            | 320              | RM-BESAN        | 12            | KG
  --   8            |                  | RM-SUGAR        | 8             | KG
  --   12           | 480              | RM-BESAN        | 10            | KG
  --
  -- Rows are gathered by product across the WHOLE file, not just while they sit
  -- next to each other: a spreadsheet that has been sorted by ingredient is
  -- still the same recipe, and silently making two half-recipes out of it would
  -- be the worst possible answer.
  --
  -- The writing itself goes through save_recipe(), so every rule lives in one
  -- place — the product must be a finished good, an ingredient must not be,
  -- quantities must be above zero, and the product's previous recipe is retired
  -- rather than left active beside the new one.
  -- ================================================================
  if p_target = 'recipes' then
    for grp in
      select normalize_item_code(x->>'item_code') as code,
             min(ord)                             as first_row,
             jsonb_agg(x order by ord)            as lines
        from jsonb_array_elements(p_rows) with ordinality as t(x, ord)
       group by 1
      having normalize_item_code(x->>'item_code') is not null
       order by min(ord)
    loop
      i := i + 1;
      begin
        select id into v_id from items where org_id = v_org and item_code = grp.code;
        if v_id is null then
          raise exception 'Product "%" is not in the item master — import it first', grp.code;
        end if;

        -- Pieces per plate is a property of the recipe, not of each ingredient,
        -- so it is taken from the first line that states it. Anybody filling
        -- this in by hand writes it once and leaves the rest blank.
        v_num := null;
        v_txt := null;
        for l in select * from jsonb_array_elements(grp.lines) loop
          if v_num is null and nullif(trim(l->>'pieces_per_plate'), '') is not null then
            v_num := (trim(l->>'pieces_per_plate'))::numeric;
          end if;
          if v_txt is null then v_txt := nullif(trim(l->>'name'), ''); end if;
        end loop;
        if coalesce(v_num, 0) <= 0 then
          raise exception 'Pieces per plate is required for "%" — put it on the first line of the recipe', grp.code;
        end if;

        v_lines := '[]'::jsonb;
        for l in select * from jsonb_array_elements(grp.lines) loop
          v_code := normalize_item_code(l->>'ingredient_code');
          if v_code is null then
            raise exception 'An ingredient line for "%" has no ingredient code', grp.code;
          end if;
          select id into v_ing from items where org_id = v_org and item_code = v_code;
          if v_ing is null then
            raise exception 'Ingredient "%" is not in the item master — add it as a raw material first', l->>'ingredient_code';
          end if;
          -- The unit is optional: without one the ingredient's own stock unit is
          -- used, which is what somebody who left the column blank expects.
          v_uom := null;
          if nullif(trim(l->>'uom'), '') is not null then
            select id into v_uom from uoms where org_id = v_org and normalize_code(code) = normalize_code(l->>'uom');
            if v_uom is null then
              raise exception 'Unknown unit "%" on ingredient % — add it under Setup → Units', l->>'uom', v_code;
            end if;
          end if;
          v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'ingredient_id', v_ing,
            'qty_per_plate', nullif(trim(l->>'qty_per_plate'), ''),
            'uom_id',        v_uom));
        end loop;

        perform save_recipe(
          jsonb_build_object('item_id', v_id, 'pieces_per_plate', v_num, 'name', v_txt),
          v_lines);

        if p_dry_run then
          raise sqlstate 'DRY00';                -- unwind this recipe's writes, keep the verdict
        end if;
        n_ok := n_ok + 1;
      exception
        when sqlstate 'DRY00' then
          n_ok := n_ok + 1;
        when others then
          n_err  := n_err + 1;
          errors := errors || jsonb_build_object('row', grp.first_row, 'error', sqlerrm,
                                                 'data', jsonb_build_object('item_code', grp.code,
                                                                            'ingredients', jsonb_array_length(grp.lines)));
      end;
    end loop;

    if not p_dry_run then
      insert into import_jobs (org_id, target, column_map, total_rows, ok_rows, error_rows, status, created_by)
      values (v_org, p_target, p_options, i, n_ok, errors, 'committed', v_staff);
    end if;
    return jsonb_build_object(
      'target', p_target, 'dry_run', p_dry_run,
      'total', i, 'ok', n_ok, 'unchanged', n_skip, 'errors', n_err,
      'error_rows', errors);
  end if;

  if p_target = 'opening_stock' then
    v_loc  := nullif(p_options->>'location_id', '')::uuid;
    v_date := coalesce(nullif(p_options->>'txn_date', '')::date, current_date);
    if v_loc is null then
      raise exception 'opening_stock needs options.location_id';
    end if;
    if not exists (select 1 from stock_locations where id = v_loc and org_id = v_org) then
      raise exception 'Stock location not found';
    end if;
    -- The same code twice in one file is ambiguous (two lots, or a repeated row?).
    -- Refuse both rows and say which, rather than guess.
    select coalesce(jsonb_object_agg(d.code, d.rows), '{}'::jsonb) into dups
    from (
      select normalize_item_code(x->>'item_code') as code, jsonb_agg(ord) as rows
      from jsonb_array_elements(p_rows) with ordinality as t(x, ord)
      group by 1
      having normalize_item_code(x->>'item_code') is not null and count(*) > 1
    ) d;
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    v_action := null;
    begin
      -- ================================================================
      if p_target = 'sections' then
        v_name := nullif(trim(r->>'name'), '');
        if v_name is null then raise exception 'name is required'; end if;
        v_code := nullif(upper(regexp_replace(coalesce(r->>'code',''), '\s+', '', 'g')), '');
        v_num  := coalesce(nullif(r->>'sort_order','')::numeric, 0);

        select id into v_id from sections where org_id = v_org and upper(name) = upper(v_name);
        if v_id is null then
          insert into sections (org_id, code, name, sort_order) values (v_org, v_code, v_name, v_num::int);
          v_action := 'inserted';
        else
          update sections set code = coalesce(v_code, code), sort_order = v_num::int where id = v_id;
          v_action := 'updated';
        end if;

      -- ================================================================
      elsif p_target = 'items' then
        v_code := normalize_item_code(r->>'item_code');
        v_name := nullif(regexp_replace(trim(coalesce(r->>'name','')), '\s+', ' ', 'g'), '');
        if v_code is null then raise exception 'item_code is required'; end if;
        if v_name is null then raise exception 'name is required'; end if;

        v_upb := nullif(trim(r->>'units_per_box'), '')::numeric::int;
        if v_upb is null or v_upb <= 0 then
          raise exception 'units_per_box is required and must be > 0 (never assumed to be 8)';
        end if;
        v_ppu := coalesce(nullif(trim(r->>'pieces_per_unit'), '')::numeric::int, 1);
        if v_ppu <= 0 then raise exception 'pieces_per_unit must be > 0'; end if;

        -- pack type: match the client's own Setup rows, L.B ≡ LB
        v_pack := null;
        v_txt := normalize_code(r->>'pack_type');
        if v_txt is not null then
          select id into v_pack from pack_types where org_id = v_org and normalize_code(code) = v_txt;
          if v_pack is null and v_make then
            insert into pack_types (org_id, code) values (v_org, upper(trim(r->>'pack_type')))
            returning id into v_pack;
          end if;
          if v_pack is null then
            raise exception 'Unknown pack type "%" — add it under Setup → Pack types, or tick "Create missing pack types and sections" and check again', r->>'pack_type';
          end if;
        end if;

        -- section by code (S-10) or by name
        v_sec := null;
        v_txt := nullif(trim(r->>'section_code'), '');
        if v_txt is not null then
          select id into v_sec from sections
           where org_id = v_org and (upper(replace(code,' ','')) = upper(replace(v_txt,' ','')) or upper(name) = upper(v_txt));
          -- Created by NAME, never by code: 'S-10' as a name would be nonsense on
          -- the stock report, and a code invented here would collide with the
          -- real one the day it arrives.
          if v_sec is null and v_make then
            insert into sections (org_id, name, sort_order)
            values (v_org, v_txt, coalesce((select max(sort_order) from sections where org_id = v_org), 0) + 1)
            returning id into v_sec;
          end if;
          if v_sec is null then
            raise exception 'Unknown section "%" — add it under Setup → Sections, or tick "Create missing pack types and sections" and check again', v_txt;
          end if;
        end if;

        -- stock-keeping unit: same code as the pack type when a unit-basis uom
        -- exists for it, else the first unit-basis uom
        v_uom := null;
        if v_pack is not null then
          select u.id into v_uom from uoms u join pack_types pt on pt.id = v_pack
           where u.org_id = v_org and u.is_active and normalize_code(u.code) = normalize_code(pt.code);
        end if;
        if v_uom is null then
          select id into v_uom from uoms where org_id = v_org and is_active and basis = 'unit'
           order by sort_order, code limit 1;
        end if;
        if v_uom is null then
          raise exception 'No unit-basis UOM exists — add JAR / PACK under Setup → Units first';
        end if;

        select id into v_id from items where org_id = v_org and item_code = v_code;
        if v_id is null then
          insert into items (org_id, item_code, name, pack_type_id, section_id, base_uom_id,
                             units_per_box, pieces_per_unit, mrp_per_piece,
                             unit_rate, purchase_rate, reorder_level, shelf_life_days)
          values (v_org, v_code, v_name, v_pack, v_sec, v_uom, v_upb, v_ppu,
                  nullif(trim(r->>'mrp_per_piece'),'')::numeric,
                  coalesce(nullif(trim(r->>'unit_rate'),'')::numeric, 0),
                  coalesce(nullif(trim(r->>'purchase_rate'),'')::numeric, 0),
                  coalesce(nullif(trim(r->>'reorder_level'),'')::numeric, 0),
                  nullif(trim(r->>'shelf_life_days'),'')::numeric::int);
          v_action := 'inserted';
        else
          -- Re-import: refresh descriptive fields; packing goes through the lock
          -- trigger (raises if the item already has stock movement and changed).
          update items set
            name            = v_name,
            pack_type_id    = coalesce(v_pack, pack_type_id),
            section_id      = coalesce(v_sec, section_id),
            units_per_box   = v_upb,
            pieces_per_unit = v_ppu,
            mrp_per_piece   = coalesce(nullif(trim(r->>'mrp_per_piece'),'')::numeric, mrp_per_piece),
            unit_rate       = coalesce(nullif(trim(r->>'unit_rate'),'')::numeric, unit_rate),
            purchase_rate   = coalesce(nullif(trim(r->>'purchase_rate'),'')::numeric, purchase_rate),
            reorder_level   = coalesce(nullif(trim(r->>'reorder_level'),'')::numeric, reorder_level),
            shelf_life_days = coalesce(nullif(trim(r->>'shelf_life_days'),'')::numeric::int, shelf_life_days)
          where id = v_id;
          v_action := 'updated';
        end if;

      -- ================================================================
      elsif p_target = 'customers' then
        v_name := nullif(trim(r->>'name'), '');
        if v_name is null then raise exception 'name is required'; end if;
        v_mobile := nullif(regexp_replace(coalesce(r->>'mobile1',''), '[^0-9]', '', 'g'), '');
        if v_mobile is null then raise exception 'mobile1 is required (it is the duplicate key)'; end if;
        if length(v_mobile) < 10 then raise exception 'mobile1 "%" is too short', r->>'mobile1'; end if;

        v_route := null;
        v_txt := nullif(trim(r->>'route'), '');
        if v_txt is not null then
          select id into v_route from routes where org_id = v_org and upper(name) = upper(v_txt);
          if v_route is null then
            insert into routes (org_id, name) values (v_org, v_txt) returning id into v_route;
          end if;
        end if;

        select id into v_id from customers where org_id = v_org and mobile1 = v_mobile;
        if v_id is null then
          insert into customers (org_id, code, name, mobile1, mobile2, mobile3, town, address, route_id,
                                 price_group, credit_limit, opening_balance, whatsapp_opt_in)
          values (v_org, nullif(trim(r->>'code'),''), v_name, v_mobile,
                  nullif(regexp_replace(coalesce(r->>'mobile2',''), '[^0-9]', '', 'g'), ''),
                  nullif(regexp_replace(coalesce(r->>'mobile3',''), '[^0-9]', '', 'g'), ''),
                  nullif(trim(r->>'town'),''), nullif(trim(r->>'address'),''), v_route,
                  coalesce(nullif(trim(r->>'price_group'),''), 'default'),
                  coalesce(nullif(trim(r->>'credit_limit'),'')::numeric, 0),
                  coalesce(nullif(trim(r->>'opening_balance'),'')::numeric, 0),
                  coalesce(lower(trim(r->>'whatsapp_opt_in')) in ('true','yes','y','1'), true));
          v_action := 'inserted';
        else
          update customers set
            name            = v_name,
            code            = coalesce(nullif(trim(r->>'code'),''), code),
            mobile2         = coalesce(nullif(regexp_replace(coalesce(r->>'mobile2',''), '[^0-9]', '', 'g'), ''), mobile2),
            mobile3         = coalesce(nullif(regexp_replace(coalesce(r->>'mobile3',''), '[^0-9]', '', 'g'), ''), mobile3),
            town            = coalesce(nullif(trim(r->>'town'),''), town),
            address         = coalesce(nullif(trim(r->>'address'),''), address),
            route_id        = coalesce(v_route, route_id),
            price_group     = coalesce(nullif(trim(r->>'price_group'),''), price_group),
            credit_limit    = coalesce(nullif(trim(r->>'credit_limit'),'')::numeric, credit_limit),
            opening_balance = coalesce(nullif(trim(r->>'opening_balance'),'')::numeric, opening_balance)
          where id = v_id;
          v_action := 'updated';
        end if;

      -- ================================================================
      elsif p_target = 'opening_stock' then
        v_code := normalize_item_code(r->>'item_code');
        if v_code is null then raise exception 'item_code is required'; end if;
        if dups ? v_code then
          raise exception 'Item "%" appears more than once in this file (rows %) — combine them into one row',
            v_code, (select string_agg(e, ', ') from jsonb_array_elements_text(dups->v_code) e);
        end if;
        select id, units_per_box into v_id, v_upb from items where org_id = v_org and item_code = v_code;
        if v_id is null then
          raise exception 'Item "%" is not in the item master — import it first', v_code;
        end if;
        v_num := coalesce(nullif(trim(r->>'opening_boxes'), '')::numeric, 0);
        v_qty := round(v_num * v_upb, 3);                 -- boxes → base units, never assumed 8

        -- Idempotent: what is already posted as opening for this item/location/date?
        select coalesce(sum(qty_base), 0) into v_have from stock_ledger
         where org_id = v_org and item_id = v_id and location_id = v_loc
           and txn_date = v_date and txn_type in ('opening','adjustment')
           and ref_table = 'import';
        if v_have = v_qty then
          v_action := 'unchanged';
        elsif v_have = 0 and v_qty <> 0 then
          insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table, created_by)
          values (v_org, v_id, v_loc, 'opening', v_date, v_qty, 'import', v_staff);
          v_action := 'inserted';
        elsif v_have = 0 and v_qty = 0 then
          v_action := 'unchanged';
        else
          -- Ledger is append-only: post the difference, never overwrite.
          insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, ref_table, created_by)
          values (v_org, v_id, v_loc, 'adjustment', v_date, v_qty - v_have, 'import', v_staff);
          v_action := 'adjusted';
        end if;

      -- ================================================================
      elsif p_target = 'rates' then
        v_code := normalize_item_code(r->>'item_code');
        if v_code is null then raise exception 'item_code is required'; end if;
        select id into v_id from items where org_id = v_org and item_code = v_code;
        if v_id is null then raise exception 'Item "%" is not in the item master', v_code; end if;
        if nullif(trim(r->>'unit_rate'),'') is null and nullif(trim(r->>'purchase_rate'),'') is null then
          raise exception 'unit_rate or purchase_rate is required';
        end if;
        update items set
          unit_rate     = coalesce(nullif(trim(r->>'unit_rate'),'')::numeric, unit_rate),
          purchase_rate = coalesce(nullif(trim(r->>'purchase_rate'),'')::numeric, purchase_rate)
        where id = v_id;
        v_action := 'updated';
      end if;

      if p_dry_run then
        raise sqlstate 'DRY00';                  -- unwind this row's writes, keep the verdict
      end if;
      if v_action = 'unchanged' then n_skip := n_skip + 1; else n_ok := n_ok + 1; end if;

    exception
      when sqlstate 'DRY00' then
        if v_action = 'unchanged' then n_skip := n_skip + 1; else n_ok := n_ok + 1; end if;
      when others then
        n_err  := n_err + 1;
        errors := errors || jsonb_build_object('row', i, 'error', sqlerrm, 'data', r);
    end;
  end loop;

  if not p_dry_run then
    insert into import_jobs (org_id, target, column_map, total_rows, ok_rows, error_rows, status, created_by)
    values (v_org, p_target, p_options, i, n_ok, errors, 'committed', v_staff);
  end if;

  return jsonb_build_object(
    'target', p_target, 'dry_run', p_dry_run,
    'total', i, 'ok', n_ok, 'unchanged', n_skip, 'errors', n_err,
    'error_rows', errors);
end $$;

revoke execute on function import_rows(text, jsonb, jsonb, boolean) from public, anon;
grant  execute on function import_rows(text, jsonb, jsonb, boolean) to authenticated;

