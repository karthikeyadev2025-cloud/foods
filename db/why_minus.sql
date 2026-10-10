-- ============================================================
-- JYOTHI FOODS ERP — WHY IS THE STOCK IN MINUS?
--
-- Paste the whole file into the Supabase SQL editor and send one screenshot of
-- the result. It changes nothing: every statement here only reads.
--
-- Stock goes below zero for exactly one reason — more has gone out on the books
-- than was ever put in on the books. The system does not stop a bill for want
-- of stock, and it should not: the goods left the shop whether or not anybody
-- typed the purchase. So minus is never a calculation fault. It is a record
-- that is missing, or a record filed in the wrong place.
--
-- This file does not fix anything. It says WHICH of the six causes it is, per
-- product, so the right thing is done. Topping the number up quietly would
-- bury the missing purchase that caused it.
--
-- Read the `finding` column. The six questions, in the order worth asking:
--
--   1  how much     how many products, and how deep
--   2  what came in  nothing at all came in, or less than went out
--   3  wrong godown  plus in one godown, minus in another — nothing is missing
--   4  no opening    the product was never given its starting stock
--   5  packing       the box size was changed after movements were recorded
--   6  duplicates    the same movement recorded twice
--   7  date order    right today, but minus on an earlier date — a bill dated
--                    before the purchase that supplied it
--
-- What this file CANNOT see: purchases still sitting unsent in the Outbox on
-- somebody's screen. Those goods are in the shop and are being billed out, and
-- the purchase has never reached the database at all. Check the Outbox first.
-- ============================================================

with

-- Every item/godown balance, with in and out separated so the size of the hole
-- is visible rather than just its sign.
bal as (
  select sl.item_id, sl.location_id,
         sum(sl.qty_base)                                        as qty,
         sum(sl.qty_base) filter (where sl.qty_base > 0)          as came_in,
         -sum(sl.qty_base) filter (where sl.qty_base < 0)         as went_out,
         count(*)                                                 as rows_n,
         min(sl.txn_date)                                         as first_moved,
         max(sl.txn_date)                                         as last_moved
    from stock_ledger sl
   group by 1, 2
),
neg as (select * from bal where qty < 0),

-- What kinds of movement the item has, per godown: 'sale 240 · purchase 120'.
-- in_kinds is everything that can ADD stock, so zero there means nothing was
-- ever recorded arriving.
mix as (
  select item_id, location_id,
         string_agg(txn_type::text || ' ' || rtrim(trim(to_char(total, 'FM999999990.999')), '.'), ' · '
                    order by total desc) as mix,
         coalesce(sum(total) filter (where txn_type in ('purchase','opening','production_in','sale_return','transfer','van_unload','adjustment')), 0) as in_kinds
    from (select item_id, location_id, txn_type, sum(abs(qty_base)) as total
            from stock_ledger group by 1, 2, 3) t
   group by 1, 2
),

-- 3. The same product sitting in the plus somewhere else. Then nothing is
--    missing at all: one of the two documents names the wrong godown.
elsewhere as (
  select n.item_id, n.location_id, n.qty as neg_qty,
         (select string_agg(l.name || ' +' || rtrim(trim(to_char(b.qty, 'FM999999990.999')), '.'), ', ' order by b.qty desc)
            from bal b join stock_locations l on l.id = b.location_id
           where b.item_id = n.item_id and b.location_id <> n.location_id and b.qty > 0) as plus_at,
         (select coalesce(sum(b.qty), 0)
            from bal b where b.item_id = n.item_id and b.location_id <> n.location_id and b.qty > 0) as plus_qty
    from neg n
),

-- 5. The box size was edited after movements were recorded. Every document
--    snapshots its own packing, so old rows stay in the old base while the
--    report divides by the new one — the units are right and the BOXES are not.
packing as (
  select i.id as item_id, i.item_code, i.name, i.units_per_box as master,
         (select string_agg(distinct x.upb::text, ', ')
            from (select units_per_box as upb from purchase_items where item_id = i.id and coalesce(units_per_box, 0) > 0
                  union select units_per_box from invoice_items where item_id = i.id and coalesce(units_per_box, 0) > 0) x
           where x.upb <> coalesce(i.units_per_box, 0)) as other_packings
    from items i
),

-- 6. The same movement twice. Two identical rows against one document is not a
--    double delivery; it is a double post.
dups as (
  select item_id, location_id, txn_type, txn_date, qty_base, ref_table, ref_id, count(*) as n
    from stock_ledger
   where ref_id is not null
   group by 1, 2, 3, 4, 5, 6, 7
  having count(*) > 1
),

-- 7. Right today, wrong in the past. The running balance dips below zero on a
--    date and climbs back, which means a bill is dated before the purchase
--    that supplied it. Today's figure is fine; every "as on" report before
--    that date is not, and that is what reads as wrong opening stock.
running as (
  select item_id, location_id, txn_date,
         sum(qty_base) over (partition by item_id, location_id order by txn_date, id) as bal
    from stock_ledger
),
dipped as (
  select r.item_id, r.location_id, min(r.bal) as worst,
         min(r.txn_date) filter (where r.bal < 0) as first_minus_on
    from running r
   group by 1, 2
),

-- ---------- the answers ----------
q1 as (
  select 1 as n, 'how much' as question, '' as item, '' as godown,
         case when (select count(*) from neg) = 0
              then 'ok — nothing is below zero'
              else 'FOUND — ' || (select count(*) from neg) || ' product/godown balances are below zero' end as finding,
         coalesce('short by ' || rtrim(trim(to_char(-(select sum(qty) from neg), 'FM999999990.999')), '.') || ' units in all, across '
                  || (select count(distinct item_id) from neg) || ' products', '') as numbers
),
q2 as (
  select 2, 'what came in', coalesce(i.item_code || ' ' || i.name, '?'), coalesce(l.name, '?'),
         case when coalesce(m.in_kinds, 0) = 0
                then 'FOUND — NOTHING was ever recorded coming in. The purchase, opening stock or batch is missing.'
              else 'FOUND — less came in than went out. Some of the purchases are missing, or one went out twice.' end,
         'in ' || rtrim(trim(to_char(coalesce(n.came_in, 0), 'FM999999990.999')), '.')
           || ' · out ' || rtrim(trim(to_char(coalesce(n.went_out, 0), 'FM999999990.999')), '.')
           || ' · balance ' || rtrim(trim(to_char(n.qty, 'FM999999990.999')), '.')
           || ' · ' || coalesce(m.mix, 'no movements')
           || ' · ' || to_char(n.first_moved, 'DD-MM-YYYY') || ' to ' || to_char(n.last_moved, 'DD-MM-YYYY')
    from neg n
    join items i on i.id = n.item_id
    left join stock_locations l on l.id = n.location_id
    left join mix m on m.item_id = n.item_id and m.location_id = n.location_id
),
q3 as (
  select 3, 'wrong godown', i.item_code || ' ' || i.name, coalesce(l.name, '?'),
         'FOUND — the same product is in the plus elsewhere: ' || e.plus_at
           || case when e.plus_qty >= -e.neg_qty
                   then '. Nothing is missing — a document names the wrong godown.'
                   else '. Part of it is only in the wrong godown.' end,
         'minus here ' || rtrim(trim(to_char(e.neg_qty, 'FM999999990.999')), '.')
           || ' · plus elsewhere ' || rtrim(trim(to_char(e.plus_qty, 'FM999999990.999')), '.')
    from elsewhere e
    join items i on i.id = e.item_id
    left join stock_locations l on l.id = e.location_id
   where e.plus_at is not null
),
q4 as (
  select 4, 'no opening', i.item_code || ' ' || i.name, coalesce(l.name, '?'),
         'FOUND — this product has gone out but was never given an opening stock, and has no purchase and no batch either.',
         'out ' || rtrim(trim(to_char(coalesce(n.went_out, 0), 'FM999999990.999')), '.') || ' units on ' || n.rows_n || ' movements'
    from neg n
    join items i on i.id = n.item_id
    left join stock_locations l on l.id = n.location_id
   where not exists (select 1 from stock_ledger s
                      where s.item_id = n.item_id
                        and s.txn_type in ('opening','purchase','production_in'))
),
q5 as (
  select 5, 'packing', p.item_code || ' ' || p.name, '',
         'FOUND — movements for this product were recorded at more than one box size, so its BOXES figure mixes two bases.',
         'product is now ' || coalesce(p.master, 0) || ' per box; documents also hold ' || p.other_packings
    from packing p
   where p.other_packings is not null
     and exists (select 1 from neg n where n.item_id = p.item_id)
),
q6 as (
  select 6, 'duplicates', coalesce(i.item_code || ' ' || i.name, '?'), coalesce(l.name, '?'),
         'FOUND — the same movement is recorded ' || d.n || ' times. Stock → Problems can remove the extras.',
         d.txn_type::text || ' ' || rtrim(trim(to_char(d.qty_base, 'FM999999990.999')), '.')
           || ' on ' || to_char(d.txn_date, 'DD-MM-YYYY') || ' from ' || coalesce(d.ref_table, '?')
    from dups d
    join items i on i.id = d.item_id
    left join stock_locations l on l.id = d.location_id
),
q7 as (
  select 7, 'date order', i.item_code || ' ' || i.name, coalesce(l.name, '?'),
         'FOUND — right today, but it was below zero on ' || to_char(d.first_minus_on, 'DD-MM-YYYY')
           || '. A bill is dated before the purchase that supplied it, so every report "as on" an earlier date is wrong.',
         'worst it reached ' || rtrim(trim(to_char(d.worst, 'FM999999990.999')), '.') || ' units'
    from dipped d
    join bal b on b.item_id = d.item_id and b.location_id = d.location_id
    join items i on i.id = d.item_id
    left join stock_locations l on l.id = d.location_id
   where d.worst < 0 and b.qty >= 0
)

select * from (
  select * from q1
  union all select * from q2
  union all select * from q3
  union all select * from q4
  union all select * from q5
  union all select * from q6
  union all select * from q7
) answers
order by n, item
limit 200;
