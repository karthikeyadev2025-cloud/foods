-- ============================================================
-- JYOTHI FOODS ERP — 37: WHAT IS WRONG WITH THE DATA
--
-- The system is right and the data is not, which is the harder half. Four
-- products show less than nothing in stock; sixty-odd came in from the price
-- list with no packing; several have no rate at all; and the opening import
-- appears to have run twice for a handful of rows.
--
-- None of that stops the shop working, which is exactly why it survives: every
-- figure derived from it is quietly wrong, and nobody is told. So these are
-- three reports and one repair, all read-only unless asked otherwise:
--
--   negative_stock()          more has gone out than ever came in, per product
--                             and per godown, with the in and out totals so the
--                             size of the hole is visible
--   item_data_problems()      one row per thing that makes a product unusable
--                             or its reports wrong
--   duplicate_stock_rows()    the same movement recorded twice
--   remove_duplicate_stock_rows()  deletes the extras — DRY RUN BY DEFAULT
--
-- Negative stock is never "fixed" by this file. It is a real difference between
-- the shelf and the book, and the honest way to close it is a stock count,
-- which posts an adjustment somebody has signed for. Silently topping the
-- number up would hide the missing purchases or batches that caused it.
--
-- FORWARD ONLY. Never run a lower-numbered file after this one.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Where the shop shows less than nothing
-- ------------------------------------------------------------
create or replace function negative_stock()
returns table (
  item_id uuid, item_code text, name text, section_name text,
  location_id uuid, location_name text,
  qty_base numeric, boxes numeric, units_per_box integer,
  came_in numeric, went_out numeric, movements bigint, last_moved date)
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_view('stock') then raise exception 'Stock is not available to your role' using errcode = '42501'; end if;
  return query
    select i.id, i.item_code, i.name, s.name,
           l.id, l.name,
           d.qty, round(d.qty / nullif(i.units_per_box, 0), 3), i.units_per_box,
           d.in_qty, d.out_qty, d.n, d.last_moved
      from (select sl.item_id, sl.location_id,
                   sum(sl.qty_base) as qty,
                   sum(sl.qty_base) filter (where sl.qty_base > 0) as in_qty,
                   -sum(sl.qty_base) filter (where sl.qty_base < 0) as out_qty,
                   count(*) as n,
                   max(sl.txn_date) as last_moved
              from stock_ledger sl
             where sl.org_id = my_org_id()
             group by 1, 2
            having sum(sl.qty_base) < 0) d
      join items i on i.id = d.item_id
      left join sections s on s.id = i.section_id
      left join stock_locations l on l.id = d.location_id
     order by d.qty;
end $$;

-- ------------------------------------------------------------
-- 2. Products the master cannot really use
-- ------------------------------------------------------------
/**
 * One row per problem, not per product, so a product with three things wrong
 * appears three times and every one of them gets fixed rather than the first.
 *
 * Judged on whether the shop can actually work with the row, not on a guess at
 * what somebody meant to type. A finished good with no rate cannot be billed;
 * one with no packing bills a box of one; one with no section is missing from
 * every section report and from its mestri's figures.
 */
create or replace function item_data_problems()
returns table (item_id uuid, item_code text, name text, problem text, fix text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_view('items') then raise exception 'Items are not available to your role' using errcode = '42501'; end if;
  return query
    select * from (
      select i.id, i.item_code, i.name, 'No rate'::text,
             'Cannot be billed — set the unit rate on the product'::text
        from items i
       where i.org_id = my_org_id() and i.is_active and i.type = 'finished_good'
         and coalesce(i.unit_rate, 0) = 0

      union all
      select i.id, i.item_code, i.name, 'No packing',
             'Units per box is 1, so a box bills as one — set how many go in a box'
        from items i
       where i.org_id = my_org_id() and i.is_active and i.type = 'finished_good'
         and coalesce(i.units_per_box, 0) <= 1

      union all
      select i.id, i.item_code, i.name, 'No section',
             'Missing from every section report and from its mestri''s figures'
        from items i
       where i.org_id = my_org_id() and i.is_active and i.type = 'finished_good'
         and i.section_id is null

      union all
      select i.id, i.item_code, i.name, 'No pack type',
             'The rate card and the bill have nothing to print after the rate'
        from items i
       where i.org_id = my_org_id() and i.is_active and i.type = 'finished_good'
         and i.pack_type_id is null

      union all
      select i.id, i.item_code, i.name, 'No cost price',
             'Every profit figure for this product reads as pure profit'
        from items i
       where i.org_id = my_org_id() and i.is_active and i.type = 'finished_good'
         and coalesce(i.purchase_rate, 0) = 0

      -- The two that stop a bill dead rather than merely skewing a report, from 29.
      union all
      select i.id, i.item_code, i.name, 'Cannot be measured', m.problem
        from items_needing_measure() m
        join items i on i.item_code = m.item_code and i.org_id = my_org_id()
    ) q(item_id, item_code, name, problem, fix)
   order by q.problem, q.name;
end $$;

-- ------------------------------------------------------------
-- 3. The same movement recorded twice
-- ------------------------------------------------------------
/**
 * Identical rows — same product, godown, kind, date, quantity and source
 * document. An import run twice is the usual cause, and the give-away is a set
 * of opening rows with no document behind them.
 */
create or replace function duplicate_stock_rows()
returns table (
  item_id uuid, item_code text, name text, location_name text,
  txn_type text, txn_date date, qty_base numeric, ref_table text, copies bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_view('stock') then raise exception 'Stock is not available to your role' using errcode = '42501'; end if;
  return query
    select i.id, i.item_code, i.name, l.name,
           d.txn_type::text, d.txn_date, d.qty_base, d.ref_table, d.n
      from (select sl.item_id, sl.location_id, sl.txn_type, sl.txn_date, sl.qty_base,
                   sl.ref_table, sl.ref_id, count(*) as n
              from stock_ledger sl
             where sl.org_id = my_org_id()
             group by 1, 2, 3, 4, 5, 6, 7
            having count(*) > 1) d
      join items i on i.id = d.item_id
      left join stock_locations l on l.id = d.location_id
     order by i.name, d.txn_date;
end $$;

/**
 * Delete the extra copies, keeping the earliest of each set.
 *
 * DRY RUN BY DEFAULT: called with nothing it only counts, so the number can be
 * read before anything is touched. Pass true to actually delete.
 *
 * SECURITY DEFINER because the stock ledger grants no DELETE to anyone — the
 * same reason delete_document needs it. Owner and admin only, and scoped to the
 * caller's own org in the statement, since RLS is not doing it here.
 */
create or replace function remove_duplicate_stock_rows(p_apply boolean default false)
returns bigint language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  if not has_role('owner', 'admin') then
    raise exception 'Only an owner or admin can clear duplicate stock rows' using errcode = '42501';
  end if;

  with dupes as (
    select sl.id,
           row_number() over (
             partition by sl.item_id, sl.location_id, sl.txn_type, sl.txn_date,
                          sl.qty_base, sl.ref_table, sl.ref_id
             order by sl.created_at, sl.id) as rn
      from stock_ledger sl
     where sl.org_id = my_org_id())
  select count(*) into n from dupes where rn > 1;

  if p_apply and n > 0 then
    delete from stock_ledger
     where id in (
       select id from (
         select sl.id,
                row_number() over (
                  partition by sl.item_id, sl.location_id, sl.txn_type, sl.txn_date,
                               sl.qty_base, sl.ref_table, sl.ref_id
                  order by sl.created_at, sl.id) as rn
           from stock_ledger sl
          where sl.org_id = my_org_id()) x
        where x.rn > 1);
  end if;

  return n;
end $$;
