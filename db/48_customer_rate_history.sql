-- ============================================================
-- JYOTHI FOODS ERP — 48: WHAT DID WE CHARGE THIS CUSTOMER LAST TIME?
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- From the counter: "customers old bill has to be want whenever they double
-- click on the customer name — its means old rates will recheck while new bill."
--
-- The rate on a new bill already comes from the price list through
-- effective_unit_rate(). That answers "what SHOULD this cost". It does not
-- answer the question actually being asked at the counter, which is "what did
-- we charge HIM last time" — because rates get given over the phone, a regular
-- has been on 40 for a year while the list says 42, and the shop is not going
-- to lose the argument in front of the customer.
--
-- Nothing recorded that. Every bill line holds the rate it was billed at, but
-- there was no way to look back at them, so the only place that knowledge lived
-- was in somebody's head.
--
-- Two functions, because two different things are being asked:
--
--   customer_last_rates()    one row per product — the last rate he actually
--                            paid, when, and on which bill. This is the one the
--                            biller wants at the moment of typing the item.
--   customer_recent_bills()  his last few bills to open and read, for when the
--                            question is about a whole bill rather than a rate.
--
-- CANCELLED BILLS ARE EXCLUDED. A cancelled bill is not a price anybody agreed
-- to; quoting a rate off one would be worse than having no history at all.
-- ============================================================

/**
 * The last rate this customer actually paid for each product.
 *
 * `distinct on` takes the first row of each group after ordering, which is the
 * newest bill line per product — one pass, no correlated subquery per item.
 * Ordered by date descending overall so the products he buys most recently come
 * to the top, which is the order a biller reads in.
 */
create or replace function customer_last_rates(p_customer uuid)
returns table (
  item_id      uuid,
  item_code    text,
  item_name    text,
  rate         numeric,
  boxes        numeric,
  invoice_id   uuid,
  invoice_no   text,
  invoice_date date,
  times_billed bigint)
language sql stable security definer set search_path = public as $$
  with mine as (
    select ii.item_id, ii.rate, ii.boxes, i.id as invoice_id, i.invoice_no, i.invoice_date
      from invoice_items ii
      join invoices i on i.id = ii.invoice_id
     where i.org_id = my_org_id()
       and i.customer_id = p_customer
       and i.status <> 'cancelled'
  ),
  latest as (
    select distinct on (m.item_id) m.*
      from mine m
     order by m.item_id, m.invoice_date desc, m.invoice_no desc
  ),
  counted as (
    select m.item_id, count(*) as times_billed from mine m group by m.item_id
  )
  select l.item_id, it.item_code, it.name, l.rate, l.boxes,
         l.invoice_id, l.invoice_no, l.invoice_date, c.times_billed
    from latest l
    join items it on it.id = l.item_id
    join counted c on c.item_id = l.item_id
   order by l.invoice_date desc, it.name;
$$;

/**
 * This customer's last few bills, newest first, for reading rather than
 * re-pricing. Cancelled ones are shown — a biller asking "what happened to that
 * bill" is entitled to see that it was cancelled — but they are marked, and
 * customer_last_rates() still refuses to quote a rate from one.
 */
create or replace function customer_recent_bills(p_customer uuid, p_limit int default 12)
returns table (
  id         uuid,
  invoice_no text,
  invoice_date date,
  status     text,
  lines      bigint,
  boxes      numeric,
  total      numeric)
language sql stable security definer set search_path = public as $$
  select i.id, i.invoice_no, i.invoice_date, i.status::text,
         count(ii.id), coalesce(sum(ii.boxes), 0), i.total
    from invoices i
    left join invoice_items ii on ii.invoice_id = i.id
   where i.org_id = my_org_id() and i.customer_id = p_customer
   group by i.id, i.invoice_no, i.invoice_date, i.status, i.total
   order by i.invoice_date desc, i.invoice_no desc
   limit greatest(1, least(coalesce(p_limit, 12), 100));
$$;

/** The lines of one bill, for opening a row of customer_recent_bills(). */
create or replace function invoice_lines_for_reading(p_invoice uuid)
returns table (
  item_code text,
  item_name text,
  boxes     numeric,
  rate      numeric,
  amount    numeric)
language sql stable security definer set search_path = public as $$
  select it.item_code, it.name, ii.boxes, ii.rate, ii.amount
    from invoice_items ii
    join invoices i on i.id = ii.invoice_id
    join items it on it.id = ii.item_id
   where ii.invoice_id = p_invoice and i.org_id = my_org_id()
   order by it.name;
$$;

-- SECURITY DEFINER, so the org check above is the only thing standing between
-- one shop and another's prices. Reading a customer's own bills is part of
-- billing him, so it follows the Invoices right rather than a new one.
revoke execute on function customer_last_rates(uuid) from public, anon;
revoke execute on function customer_recent_bills(uuid, int) from public, anon;
revoke execute on function invoice_lines_for_reading(uuid) from public, anon;
grant  execute on function customer_last_rates(uuid) to authenticated;
grant  execute on function customer_recent_bills(uuid, int) to authenticated;
grant  execute on function invoice_lines_for_reading(uuid) to authenticated;
