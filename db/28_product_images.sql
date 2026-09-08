-- ============================================================
-- JYOTHI FOODS ERP — 28: A PHOTO ON THE PRODUCT, AND A RATE CARD
--
-- Two things, and the split between them is deliberate:
--
--   the photo        part of the item master, so it is `core` — every plan,
--                    including Starter. A sweet shop's product without its
--                    picture is half a record.
--   the rate card    a printable catalogue of chosen items with photo, pack
--                    and rate. Also core: the shop prints it, or saves it as
--                    a PDF and sends it from their own phone.
--
-- Pushing that catalogue to a whole town over WhatsApp stays where the rest of
-- messaging is — Full. That is the part that saves labour rather than making
-- something, and it already exists (broadcasts, kind 'catalog').
--
-- So Starter can make and hand out a rate card. Full can blast it.
-- ============================================================

alter table items
  /** Public URL in the `products` bucket. Public because it goes on a shared rate card. */
  add column if not exists image_url text;

-- The bucket itself is in db/storage/buckets.sql: the storage schema exists only on
-- Supabase, so apply.sh cannot create it and this file must not try.

-- ------------------------------------------------------------
-- 2. The list view carries it, so the item list can show a thumbnail
-- ------------------------------------------------------------
/**
 * Appended at the END. `create or replace view` may add columns but never remove
 * or reorder them, so a later file can only ever grow this view — which is why
 * this lives here rather than as an edit to 08_masters.sql.
 */
create or replace view v_item_list as
select i.id, i.org_id, i.item_code, i.name, i.type, i.is_active, i.created_at,
       i.pack_type_id, pt.code as pack_code,
       i.section_id, s.code as section_code, s.name as section_name, coalesce(s.sort_order, 999) as section_sort,
       i.base_uom_id, u.code as base_uom_code,
       i.units_per_box, i.pieces_per_unit, i.mrp_per_piece, i.net_weight_g,
       i.unit_rate, i.box_rate, i.purchase_rate, i.reorder_level, i.shelf_life_days,
       (exists (select 1 from stock_ledger sl where sl.item_id = i.id)) as has_stock_movement,
       coalesce((select sum(sl.qty_base) from stock_ledger sl where sl.item_id = i.id), 0::numeric) as stock_base,
       i.image_url
  from items i
  left join pack_types pt on pt.id = i.pack_type_id
  left join sections s on s.id = i.section_id
  left join uoms u on u.id = i.base_uom_id;
alter view v_item_list set (security_invoker = on);

-- ------------------------------------------------------------
-- 3. What a rate card is made of
-- ------------------------------------------------------------
/**
 * The items for a printed catalogue: a section, a hand-picked list, or everything
 * active. Rates are the item's own; a customer-specific card is a different job and
 * would need the price list, so this deliberately does not pretend to do it.
 *
 * with_image_only exists because a rate card of empty boxes looks worse than a
 * shorter one.
 */
create or replace function catalogue_items(
  p_section uuid default null,
  p_items uuid[] default null,
  p_with_image_only boolean default false)
returns table (id uuid, item_code text, name text, section_name text, pack text,
               units_per_box integer, unit_rate numeric, box_rate numeric, image_url text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_view('items') then raise exception 'Items are not available to your role'; end if;
  return query
    select i.id, i.item_code, i.name, s.name, pt.code,
           i.units_per_box, i.unit_rate, i.box_rate, i.image_url
      from items i
      left join sections s on s.id = i.section_id
      left join pack_types pt on pt.id = i.pack_type_id
     where i.org_id = my_org_id() and i.is_active
       and (p_section is null or i.section_id = p_section)
       and (p_items is null or i.id = any(p_items))
       and (not p_with_image_only or i.image_url is not null)
     order by s.sort_order nulls last, s.name nulls last, i.name;
end $$;

-- ------------------------------------------------------------
-- 4. The picture travels with the item in a backup
-- ------------------------------------------------------------
-- (items is already in snapshot_tables(); image_url is just another column on it,
--  so nothing to add. The FILE lives in storage and is not part of the JSON
--  snapshot — same as the logo and the catalog PDFs. Worth knowing before anyone
--  assumes a restore brings the photos back: it brings the links back, and the
--  files are still in the bucket unless somebody emptied it.)
