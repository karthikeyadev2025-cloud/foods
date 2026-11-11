-- ============================================================
-- JYOTHI FOODS ERP — 65: TWO REPORTS THE SHOP ASKED FOR
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- 1. VEHICLE-WISE. The shop sends its own vans out, so the bill now records a
--    driver and a vehicle number rather than a transporter and a consignment
--    note. One vehicle carries several customers in a day, and nobody could
--    see what a given van took out: the question "what went on AP16 TC 1234
--    on Tuesday" had no answer but leafing through bills.
--
--    The vehicle number lives in invoices.lr_no, which is what that column has
--    always been used for here. It is typed by hand, so it is matched on its
--    letters and digits alone — "ap16tc1234", "AP 16 TC 1234" and
--    "AP-16-TC-1234" are one vehicle, which is the only way a typed field is
--    ever going to group.
--
-- 2. SUPPLIER-WISE. Customers have a ledger, an ageing report and a statement.
--    Suppliers had a payable figure on a list and nothing else — no way to see
--    what was bought from whom, what was returned, what was paid, or what is
--    left owing, over a period.
--
--    supplier_report gives one row per supplier for the period, and
--    supplier_ledger gives the transactions behind any one of them, the same
--    shape customer_ledger has: opening, then every bill, return and payment,
--    with a running balance. A supplier's balance is what the SHOP owes, so a
--    purchase is a credit and a payment is a debit — the mirror of a customer.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Vehicle-wise
-- ------------------------------------------------------------

/**
 * A typed vehicle number reduced to what it actually is: letters and digits,
 * upper case. Spaces, hyphens and dots are how different people write the same
 * van, and grouping on the raw text would file each spelling separately.
 */
create or replace function vehicle_key(p_text text) returns text
language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(p_text, ''), '[^A-Za-z0-9]', '', 'g')), '');
$$;

create or replace function vehicle_report(
  p_org uuid, p_from date, p_to date, p_vehicle text default null
) returns table (
  vehicle text, vehicle_key text, driver text,
  invoice_id uuid, invoice_no text, invoice_date date,
  customer text, town text, route_name text,
  boxes numeric, amount numeric, status text
) language sql stable as $$
  select
    -- The spelling as the counter last typed it, so the report reads the way
    -- the bills do; vehicle_key is what the grouping is actually on.
    i.lr_no, vehicle_key(i.lr_no), i.transport_name,
    i.id, i.invoice_no, i.invoice_date,
    c.name, c.town, r.name,
    coalesce((select sum(ii.boxes) from invoice_items ii where ii.invoice_id = i.id), 0),
    i.total, i.status::text
  from invoices i
  join customers c on c.id = i.customer_id
  left join routes r on r.id = c.route_id
  where i.org_id = p_org
    and i.status <> 'cancelled'
    and vehicle_key(i.lr_no) is not null
    and i.invoice_date between p_from and p_to
    and (p_vehicle is null or vehicle_key(i.lr_no) = vehicle_key(p_vehicle))
  order by vehicle_key(i.lr_no), i.invoice_date, i.invoice_no;
$$;

/** One line per vehicle for the period — the summary above the detail. */
create or replace function vehicle_summary(
  p_org uuid, p_from date, p_to date
) returns table (
  vehicle text, vehicle_key text, drivers text,
  trips bigint, customers bigint, boxes numeric, amount numeric,
  first_run date, last_run date
) language sql stable as $$
  select
    (array_agg(v.vehicle order by v.invoice_date desc))[1],   -- the latest spelling
    v.vehicle_key,
    (select string_agg(distinct d.driver, ', ') from (
       select driver from vehicle_report(p_org, p_from, p_to) x
        where x.vehicle_key = v.vehicle_key and x.driver is not null) d),
    count(*), count(distinct v.customer), sum(v.boxes), sum(v.amount),
    min(v.invoice_date), max(v.invoice_date)
  from vehicle_report(p_org, p_from, p_to) v
  group by v.vehicle_key
  order by sum(v.amount) desc;
$$;

grant execute on function vehicle_key(text) to authenticated;
grant execute on function vehicle_report(uuid, date, date, text) to authenticated;
grant execute on function vehicle_summary(uuid, date, date) to authenticated;

-- ------------------------------------------------------------
-- 2. Supplier-wise
-- ------------------------------------------------------------
create or replace function supplier_report(
  p_org uuid, p_from date, p_to date
) returns table (
  supplier_id uuid, supplier text, town text, mobile text,
  opening numeric, purchases numeric, returns numeric, payments numeric, closing numeric,
  bills bigint, last_bill date
) language sql stable as $$
  with pur as (
    select p.supplier_id, p.bill_date, p.total from purchases p where p.org_id = p_org and p.supplier_id is not null),
  ret as (
    select pr.supplier_id, pr.return_date, pr.total from purchase_returns pr where pr.org_id = p_org and pr.supplier_id is not null),
  pay as (
    select pm.supplier_id, pm.payment_date, pm.amount from payments pm where pm.org_id = p_org and pm.supplier_id is not null)
  select s.id, s.name, s.town, s.mobile1,
         -- what was owed before the period started
         coalesce(s.opening_balance, 0)
           + coalesce((select sum(total)  from pur where supplier_id = s.id and bill_date   < p_from), 0)
           - coalesce((select sum(total)  from ret where supplier_id = s.id and return_date < p_from), 0)
           - coalesce((select sum(amount) from pay where supplier_id = s.id and payment_date < p_from), 0),
         coalesce((select sum(total)  from pur where supplier_id = s.id and bill_date   between p_from and p_to), 0),
         coalesce((select sum(total)  from ret where supplier_id = s.id and return_date between p_from and p_to), 0),
         coalesce((select sum(amount) from pay where supplier_id = s.id and payment_date between p_from and p_to), 0),
         -- and after it
         coalesce(s.opening_balance, 0)
           + coalesce((select sum(total)  from pur where supplier_id = s.id and bill_date   <= p_to), 0)
           - coalesce((select sum(total)  from ret where supplier_id = s.id and return_date <= p_to), 0)
           - coalesce((select sum(amount) from pay where supplier_id = s.id and payment_date <= p_to), 0),
         (select count(*)        from pur where supplier_id = s.id and bill_date between p_from and p_to),
         (select max(bill_date)  from pur where supplier_id = s.id and bill_date <= p_to)
    from suppliers s
   where s.org_id = p_org
     -- a supplier with nothing at all in the period and nothing owed is noise
   order by 9 desc, 2;
$$;

/**
 * The transactions behind one supplier, the shape customer_ledger has.
 * A supplier's balance is what the SHOP owes, so the signs are mirrored: a
 * bill is a credit and a payment is a debit.
 */
create or replace function supplier_ledger(
  p_supplier uuid, p_from date default null, p_to date default null
) returns table (
  entry_date date, doc text, doc_no text, doc_id uuid, particulars text,
  debit numeric, credit numeric, balance numeric
) language sql stable as $$
  with s as (select * from suppliers where id = p_supplier),
  docs as (
    select p.bill_date as d, 'Purchase' as doc, p.bill_no as doc_no, p.id,
           format('%s lines', (select count(*) from purchase_items pi where pi.purchase_id = p.id)) as particulars,
           0::numeric as debit, p.total as credit, 1 as ord
      from purchases p where p.supplier_id = p_supplier
    union all
    select pm.payment_date, 'Payment', pm.payment_no, pm.id,
           coalesce(pm.narration, pm.reference, ''), pm.amount, 0, 2
      from payments pm where pm.supplier_id = p_supplier
    union all
    select pr.return_date, 'Purchase return', pr.return_no, pr.id,
           coalesce(pr.notes, ''), pr.total, 0, 3
      from purchase_returns pr where pr.supplier_id = p_supplier),
  opening as (
    select coalesce((select opening_balance from s), 0)
         + coalesce((select sum(credit - debit) from docs where p_from is not null and d < p_from), 0) as bal),
  rows as (
    select null::date as d, 'Opening' as doc, null::text as doc_no, null::uuid as id, 'Opening balance' as particulars,
           case when bal < 0 then -bal else 0 end as debit, case when bal >= 0 then bal else 0 end as credit,
           0 as ord, 0::numeric as sortkey
      from opening
    union all
    select d, doc, doc_no, id, particulars, debit, credit, ord, extract(epoch from d)::numeric
      from docs where (p_from is null or d >= p_from) and (p_to is null or d <= p_to))
  select d, doc, doc_no, id, particulars, debit, credit,
         sum(credit - debit) over (order by sortkey, ord, doc_no rows unbounded preceding)
    from rows
   order by sortkey, ord, doc_no;
$$;

grant execute on function supplier_report(uuid, date, date) to authenticated;
grant execute on function supplier_ledger(uuid, date, date) to authenticated;
