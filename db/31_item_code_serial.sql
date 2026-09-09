-- ============================================================
-- JYOTHI FOODS ERP — 31: THE NEXT ITEM CODE
--
-- Item codes were typed by hand on every new product. Uniqueness was already
-- enforced — items carries UNIQUE (org_id, item_code) and Add Product checks
-- before saving — but "unique" and "in order" are different things, and the
-- shop wants the second: a running serial, so the code says where a product
-- sits in the master rather than being whatever number somebody remembered was
-- free.
--
-- Typing them by hand also made the check a nuisance rather than a safeguard:
-- you find out the code is taken after filling in the whole form.
--
-- The master this runs on is not purely numeric. Real codes read 8, 12, 27A,
-- 06A — the letter marks a repack of an existing product, and that convention
-- has to survive. So the serial only ever looks at codes that are entirely
-- digits, takes the highest, and adds one. A repack stays a hand-typed 27A and
-- never disturbs the count.
--
-- Deliberately a suggestion, not an enforcement. The screen fills it in and the
-- person can overwrite it — the unique index is what actually guarantees the
-- code is free, and it stays the last word.
--
-- FORWARD ONLY. Never run a lower-numbered file after this one.
-- ============================================================

/**
 * The next free serial item code for this org: the highest all-digits code plus
 * one, as text. Returns '1' for an empty master.
 *
 * Not zero-padded, matching how the client already writes them (8, not 008) and
 * what normalizeItemCode() in the app promises.
 */
create or replace function next_item_code()
returns text
language plpgsql stable security definer set search_path = public as $$
declare v_max bigint;
begin
  if not can_view('items') then
    raise exception 'Items are not available to your role' using errcode = '42501';
  end if;

  -- `~ '^[0-9]+$'` keeps 27A and 06A out of the arithmetic without throwing on
  -- them, and the length guard keeps a nonsense 40-digit code from overflowing
  -- bigint on the cast.
  select coalesce(max(item_code::bigint), 0)
    into v_max
    from items
   where org_id = my_org_id()
     and item_code ~ '^[0-9]{1,18}$';

  return (v_max + 1)::text;
end $$;
