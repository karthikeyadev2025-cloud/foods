-- ============================================================
-- JYOTHI FOODS ERP — 40: "NO ITEMS TO COUNT" NOW SAYS WHICH NOTHING
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- From a real screen: opening a stock count came back
--
--   P0001 No items to count
--
-- on a database holding a couple of hundred products. The sheet is built from
-- ACTIVE FINISHED GOODS, filtered by the section chosen in the dialog, and the
-- usual cause is that the chosen section has no products in it — which the
-- message never mentioned, so the answer looked like "the system has lost my
-- items" rather than "that dropdown".
--
-- Three different nothings reach the same dead end, and they need three
-- different things done about them, so now they say so. Nothing else about the
-- count changes.
-- ============================================================

create or replace function open_stock_count(
  p_location uuid,
  p_date     date default current_date,
  p_section  uuid default null,
  p_notes    text default null
) returns uuid
language plpgsql as $$
declare
  v_org uuid := my_org_id();
  v_id  uuid;
  n     int;
  v_all int;
begin
  if not exists (select 1 from stock_locations where id = p_location and org_id = v_org) then
    raise exception 'Location not found';
  end if;
  if exists (
    select 1 from stock_counts
     where org_id = v_org and location_id = p_location and status = 'open'
       and (p_section is null or section_id = p_section))
  then
    raise exception 'A count is already open for this location; post or cancel it first';
  end if;

  insert into stock_counts (org_id, count_no, location_id, section_id, count_date, notes, created_by)
  values (v_org, next_doc_no(v_org, 'stock_count'), p_location, p_section, p_date, p_notes, my_staff_id())
  returning id into v_id;

  insert into stock_count_items (count_id, item_id, units_per_box, system_base)
  select v_id, i.id, i.units_per_box, location_stock_base(i.id, p_location, p_date)
    from items i
   where i.org_id = v_org and i.is_active and i.type = 'finished_good'
     and (p_section is null or i.section_id = p_section);
  get diagnostics n = row_count;

  if n = 0 then
    -- Which nothing? Asked in the order that makes the next step obvious.
    select count(*) into v_all from items where org_id = v_org and type = 'finished_good';
    if v_all = 0 then
      raise exception 'There are no products yet — import the item master under Setup → Import data first';
    end if;

    select count(*) into v_all
      from items where org_id = v_org and type = 'finished_good' and is_active;
    if v_all = 0 then
      raise exception 'Every product is set inactive, so there is nothing to count. Tick "Show inactive" on the Items screen to bring one back.';
    end if;

    if p_section is not null then
      raise exception '% has no active products in it. Choose "All sections", or put products in that section first.',
        coalesce((select name from sections where id = p_section and org_id = v_org), 'That section');
    end if;

    -- Unreachable while the three checks above hold, and kept so a future change
    -- that breaks them fails loudly rather than opening an empty count sheet.
    raise exception 'No products matched, so there is nothing to count';
  end if;

  return v_id;
end $$;
