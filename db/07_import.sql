-- ============================================================
-- JYOTHI FOODS ERP — 07: IN-APP DATA IMPORT (T0.5)
--
-- "Import is a screen, not a script." The browser parses the file
-- and maps columns; this function does the actual work so it is
-- transactional, idempotent, and testable with psql.
--
--   import_rows(p_target, p_rows, p_options, p_dry_run) -> jsonb
--     p_target  'sections' | 'items' | 'customers' | 'opening_stock' | 'rates'
--     p_rows    jsonb array of objects keyed by the target's field names
--     p_options jsonb, e.g. {"location_id": "...", "txn_date": "2026-09-06"}
--     p_dry_run true  = validate every row, write nothing
--
-- Every row runs in its own sub-transaction: a bad row is reported,
-- the good ones still land. Re-importing the same file is a no-op.
-- ============================================================

-- Item codes are TEXT: strip spaces and colons, upper-case. Never cast.
create or replace function normalize_item_code(p text) returns text
language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(p, ''), '[\s:]+', '', 'g')), '');
$$;

-- 'L.B' and 'LB' are the same pack type.
create or replace function normalize_code(p text) returns text
language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(p, ''), '[\s.]+', '', 'g')), '');
$$;

-- The caller's staff row id, for created_by columns. Definer rights so any
-- invoker-rights function can use it without touching the auth schema.
create or replace function my_staff_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from staff where auth_uid = auth.uid() and is_active limit 1;
$$;

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
begin
  if v_org is null then
    raise exception 'Not signed in to an organisation';
  end if;
  if p_target not in ('sections','items','customers','opening_stock','rates') then
    raise exception 'Unknown import target %', p_target;
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a JSON array';
  end if;

  v_staff := my_staff_id();

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
          if v_pack is null then
            raise exception 'Unknown pack type "%" — add it under Setup → Pack types', r->>'pack_type';
          end if;
        end if;

        -- section by code (S-10) or by name
        v_sec := null;
        v_txt := nullif(trim(r->>'section_code'), '');
        if v_txt is not null then
          select id into v_sec from sections
           where org_id = v_org and (upper(replace(code,' ','')) = upper(replace(v_txt,' ','')) or upper(name) = upper(v_txt));
          if v_sec is null then
            raise exception 'Unknown section "%" — add it under Setup → Sections', v_txt;
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
