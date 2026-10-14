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
--   6  double post   the same movement recorded twice with nothing taking it back
--   7  date order    right today, but minus on an earlier date — a bill dated
--                    before the purchase that supplied it
--   8  saved again   one document saved over and over, in matched pairs that
--                    cancel: the balance is right, the ledger is enormous
--   9  earlier days  a bill corrected on a different day from the one it was
--                    for, so every report in between is wrong while today is
--                    right — this is what fills the OPENING column with minus
--
-- What this file CANNOT see: purchases still sitting unsent in the Outbox on
-- somebody's screen. Those goods are in the shop and are being billed out, and
-- the purchase has never reached the database at all. Check the Outbox first.
-- ============================================================

with

-- Goods arriving and goods leaving, told apart by the KIND of movement rather
-- than by the sign of the row. The sign alone lies: reopening a bill for
-- correction writes a positive 'sale' row (db/30) and correcting a purchase
-- writes a negative 'purchase' row (db/58), and neither is a lorry at the door.
-- Counting those as stock arriving is how a product with no purchase at all
-- still shows hundreds of units "came in". So each kind is NETTED within
-- itself: a bill and its correction cancel, and what is left is the truth.
arrivals as (
  select sl.item_id, sl.location_id, sl.txn_type,
         sl.txn_type in ('opening','purchase','production_in','sale_return',
                         'transfer','van_unload','adjustment') as is_in,
         sum(sl.qty_base) as net,
         count(*) filter (where (sl.qty_base > 0) <> (sl.txn_type in
           ('opening','purchase','production_in','sale_return','transfer','van_unload','adjustment'))) as corrections,
         min(sl.txn_date) as first_moved, max(sl.txn_date) as last_moved,
         count(*) as rows_n
    from stock_ledger sl
   group by 1, 2, 3
),
bal as (
  select item_id, location_id,
         sum(net)                                      as qty,
         coalesce(sum(net) filter (where is_in), 0)     as came_in,
         coalesce(-sum(net) filter (where not is_in), 0) as went_out,
         sum(corrections)                               as corrections,
         sum(rows_n)                                    as rows_n,
         min(first_moved)                               as first_moved,
         max(last_moved)                                as last_moved
    from arrivals
   group by 1, 2
),
neg as (select * from bal where qty < 0),

-- What kinds of movement the item has, per godown, signed and netted:
-- 'sale -400 · purchase +348'.
mix as (
  select item_id, location_id,
         string_agg(txn_type::text || ' ' || case when net > 0 then '+' else '' end
                    || rtrim(trim(to_char(net, 'FM999999990.999')), '.'), ' · '
                    order by abs(net) desc) as mix,
         coalesce(sum(net) filter (where is_in), 0) as in_kinds
    from arrivals
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

-- 6 and 8. Two very different things look alike here, and telling somebody to
--    delete the wrong one would break the stock.
--
--    A DOUBLE POST is a movement recorded twice with nothing taking it back:
--    every row for that document and product leans the same way. Removing the
--    extras is right, and the balance is wrong until they go.
--
--    CHURN is a document saved over and over, each save writing a reversal and
--    a fresh posting. The rows come in matched pairs that cancel, so the
--    balance is RIGHT and deleting "the extras" would wreck it. What is wrong
--    there is the sheer number of rows — which is what made stock_ledger
--    33 MB holding four rows' worth of stock, and what makes a save time out.
doc_item as (
  select item_id, location_id, ref_table, ref_id,
         count(*)                                   as rows_n,
         count(*) filter (where qty_base > 0)        as pos_n,
         count(*) filter (where qty_base < 0)        as neg_n,
         sum(qty_base)                               as net,
         min(created_at)                             as first_written,
         max(created_at)                             as last_written
    from stock_ledger
   where ref_id is not null
   group by 1, 2, 3, 4
),
-- How many LINES a document has for a product. A bill may carry the same
-- product twice on purpose — two rates, two batches, or simply typed twice —
-- and two ledger rows for two lines is not a double post. Only rows beyond the
-- lines that asked for them are.
doc_lines as (
  select 'purchases'::text as ref_table, purchase_id as ref_id, item_id, count(*) as lines_n
    from purchase_items group by 1, 2, 3
  union all
  select 'invoices', invoice_id, item_id, count(*) from invoice_items group by 1, 2, 3
  union all
  select 'sales_returns', return_id, item_id, count(*) from sales_return_items group by 1, 2, 3
),
dups as (
  select d.item_id, d.location_id, d.ref_table, d.ref_id, d.rows_n,
         coalesce(dl.lines_n, 1) as lines_n,
         (select max(sl.qty_base) from stock_ledger sl
           where sl.ref_id = d.ref_id and sl.ref_table = d.ref_table
             and sl.item_id = d.item_id and sl.location_id = d.location_id) as qty_base,
         (select max(sl.txn_date) from stock_ledger sl
           where sl.ref_id = d.ref_id and sl.ref_table = d.ref_table
             and sl.item_id = d.item_id and sl.location_id = d.location_id) as txn_date
    from doc_item d
    left join doc_lines dl on dl.ref_table = d.ref_table and dl.ref_id = d.ref_id and dl.item_id = d.item_id
   -- one-sided (nothing takes it back) AND more rows than the document has
   -- lines for this product
   where (d.pos_n = 0 or d.neg_n = 0) and d.rows_n > coalesce(dl.lines_n, 1)
),
churn as (
  select d.*, i.item_code, i.name,
         coalesce((select p.bill_no from purchases p where p.id = d.ref_id),
                  (select v.invoice_no from invoices v where v.id = d.ref_id)) as doc_no,
         extract(epoch from (d.last_written - d.first_written))::bigint as seconds
    from doc_item d
    join items i on i.id = d.item_id
   where d.rows_n >= 4 and d.pos_n > 0 and d.neg_n > 0
),

-- 9. A document whose rows sit on two different dates. Correcting a bill used
--    to take the goods back on TODAY's date while the re-made bill posted on
--    the BILL's date, so between those two days the bill counted twice and
--    every "as on" report in between was wrong — which is what fills the stock
--    report's opening column with minus while today comes out right (db/62).
--    db/62 stops new ones; the ones already written stay, and this names them.
doc_day as (
  select ref_table, ref_id, item_id, location_id, txn_date, sum(qty_base) as day_net
    from stock_ledger where ref_id is not null
   group by 1, 2, 3, 4, 5
),
doc_run as (
  select d.*,
         sum(day_net) over (partition by ref_table, ref_id, item_id, location_id order by txn_date) as upto,
         sum(day_net) over (partition by ref_table, ref_id, item_id, location_id)                   as final
    from doc_day d
),
split as (
  select ref_table, ref_id, item_id, location_id,
         max(abs(upto - final))                                      as worst_gap,
         (array_agg(txn_date order by abs(upto - final) desc, txn_date))[1] as wrong_from,
         max(txn_date)                                               as right_again,
         max(final)                                                  as final
    from doc_run
   group by 1, 2, 3, 4
  having count(*) > 1 and max(abs(upto - final)) > 0
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
         'goods in ' || rtrim(trim(to_char(coalesce(n.came_in, 0), 'FM999999990.999')), '.')
           || ' · gone out ' || rtrim(trim(to_char(coalesce(n.went_out, 0), 'FM999999990.999')), '.')
           || ' · balance ' || rtrim(trim(to_char(n.qty, 'FM999999990.999')), '.')
           || ' · ' || coalesce(m.mix, 'no movements')
           || case when coalesce(n.corrections, 0) > 0
                   then ' · ' || n.corrections || ' of these rows are corrections, already netted off'
                   else '' end
           || ' · ' || to_char(n.first_moved, 'DD-MM-YYYY') || ' to ' || to_char(n.last_moved, 'DD-MM-YYYY')
    from neg n
    join items i on i.id = n.item_id
    left join stock_locations l on l.id = n.location_id
    left join mix m on m.item_id = n.item_id and m.location_id = n.location_id
   order by n.qty
   limit 80
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
   order by n.qty
   limit 80
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
  select 6, 'double post', coalesce(i.item_code || ' ' || i.name, '?'), coalesce(l.name, '?'),
         'FOUND — this movement is recorded ' || d.rows_n || ' times for '
           || d.lines_n || ' line' || case when d.lines_n = 1 then '' else 's' end
           || ' on the document, with nothing taking the extras back, so the stock is wrong by them. Stock → Problems can remove them.',
         rtrim(trim(to_char(d.qty_base, 'FM999999990.999')), '.')
           || ' on ' || to_char(d.txn_date, 'DD-MM-YYYY') || ' from ' || coalesce(d.ref_table, '?')
    from dups d
    join items i on i.id = d.item_id
    left join stock_locations l on l.id = d.location_id
   order by d.rows_n desc
   limit 80
),
q7 as (
  -- Two different things leave a product right today and below zero earlier,
  -- and saying the wrong one sends the shop hunting for a bill that is not the
  -- problem. So this asks section 9 first: where a correction landed on a
  -- different day from the posting it was correcting, that IS the cause, and
  -- it is named rather than guessed at.
  select 7, 'date order', i.item_code || ' ' || i.name, coalesce(l.name, '?'),
         'FOUND — right today, but it was below zero on ' || to_char(d.first_minus_on, 'DD-MM-YYYY')
           || '. ' || case when exists (select 1 from split s
                                         where s.item_id = d.item_id and s.location_id = d.location_id
                                           and d.first_minus_on between s.wrong_from and s.right_again)
                           then 'A document was corrected on a different day from the one it was for and is counted twice in between — section 9 names it.'
                           else 'Goods went out before anything recorded them coming in: a bill dated before the purchase that supplied it.' end,
         'worst it reached ' || rtrim(trim(to_char(d.worst, 'FM999999990.999')), '.') || ' units'
    from dipped d
    join bal b on b.item_id = d.item_id and b.location_id = d.location_id
    join items i on i.id = d.item_id
    left join stock_locations l on l.id = d.location_id
   where d.worst < 0 and b.qty >= 0
   order by d.worst
   limit 80
),
q8 as (
  select 8, 'saved over and over', c.item_code || ' ' || c.name, coalesce(l.name, '?'),
         'FOUND — ' || coalesce(c.ref_table, '?') || ' ' || coalesce(c.doc_no, '?')
           || ' has written ' || c.rows_n || ' stock rows for this one product ('
           || c.pos_n || ' in, ' || c.neg_n || ' out) where it should have written 1. '
           || case when c.net = 0
                   then 'They cancel to nothing, so this product is not on the bill any more.'
                   else 'They cancel down to ' || rtrim(trim(to_char(c.net, 'FM999999990.999')), '.')
                        || ', which is the bill — the BALANCE IS RIGHT. Do not delete these rows.' end,
         'all written between ' || to_char(c.first_written, 'DD-MM-YYYY HH24:MI:SS')
           || ' and ' || to_char(c.last_written, 'DD-MM-YYYY HH24:MI:SS')
           || ' — ' || case when c.seconds < 120
                            then c.seconds || ' seconds apart, so nobody typed this: something saved it in a loop'
                            else (c.seconds / 3600) || ' hours apart, so these are hand edits' end
    from churn c
    left join stock_locations l on l.id = c.location_id
   order by c.rows_n desc
   limit 80
),
q9 as (
  select 9, 'wrong on earlier days', i.item_code || ' ' || i.name, coalesce(l.name, '?'),
         'FOUND — ' || coalesce(s.ref_table, '?') || ' '
           || coalesce((select p.bill_no from purchases p where p.id = s.ref_id),
                       (select v.invoice_no from invoices v where v.id = s.ref_id),
                       (select t.return_no from sales_returns t where t.id = s.ref_id), '?')
           || ' was corrected on a different day from the one it was for, so every stock report between '
           || to_char(s.wrong_from, 'DD-MM-YYYY') || ' and ' || to_char(s.right_again, 'DD-MM-YYYY')
           || ' is out by ' || rtrim(trim(to_char(s.worst_gap, 'FM999999990.999')), '.')
           || ' units on this product. Today is right (db/62).',
         'it should hold ' || rtrim(trim(to_char(s.final, 'FM999999990.999')), '.')
           || ' on every day from ' || to_char(s.wrong_from, 'DD-MM-YYYY')
    from split s
    join items i on i.id = s.item_id
    left join stock_locations l on l.id = s.location_id
   order by s.worst_gap desc
   limit 80
),
tally as (
  select 0 as n, 'how many of each' as question, '' as item, '' as godown,
         'Sections found: 2 → ' || (select count(*) from neg)
           || ' · 4 → ' || (select count(*) from neg n where not exists (
                select 1 from stock_ledger s where s.item_id = n.item_id
                 and s.txn_type in ('opening','purchase','production_in')))
           || ' · 6 → ' || (select count(*) from dups)
           || ' · 7 → ' || (select count(*) from dipped d join bal b on b.item_id = d.item_id
                             and b.location_id = d.location_id where d.worst < 0 and b.qty >= 0)
           || ' · 8 → ' || (select count(*) from churn)
           || ' · 9 → ' || (select count(*) from split) as finding,
         'each section shows at most 80 rows, worst first — a bigger number here means there are more of them' as numbers
)

select * from (
  select * from tally
  union all select * from q1
  union all select * from q2
  union all select * from q3
  union all select * from q4
  union all select * from q5
  union all select * from q6
  union all select * from q7
  union all select * from q8
  union all select * from q9
) answers
order by n, item
limit 800;
