-- ============================================================
-- JYOTHI FOODS ERP — 12: DASHBOARD & REPORTS (T5)
-- Every figure here is a SUM over the same tables the screens
-- write (invoices, receipts, sales_returns, stock_ledger, journal).
-- No report keeps its own numbers.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Receipts & payments register — the client's exact columns:
--    S.No · Name · Town · Total Outstanding · <one column per mode> ·
--    Fresh Return · Rate Difference · Return · Remaining Outstanding
--    Total Outstanding = what the customer owed with all bills up to
--    the end of the period, before this period's collections;
--    Remaining = outstanding as at the end of the period.
-- ------------------------------------------------------------
drop function if exists receipts_register(uuid, date, date, uuid);
create or replace function receipts_register(
  p_org uuid, p_from date, p_to date, p_route uuid default null
) returns table (
  sno bigint, customer_id uuid, name text, town text, route_name text,
  total_outstanding numeric,
  by_mode jsonb,
  fresh_return numeric, rate_difference numeric, damage_return numeric,
  remaining_outstanding numeric
) language sql stable as $$
  with billed as (
    select customer_id, sum(total) amt from invoices
     where org_id = p_org and status <> 'cancelled' and invoice_date <= p_to group by customer_id),
  paid_before as (
    select customer_id, sum(total_amount) amt from receipts
     where org_id = p_org and receipt_date < p_from group by customer_id),
  ret_before as (
    select customer_id, sum(total) amt from sales_returns
     where org_id = p_org and return_date < p_from group by customer_id),
  lines as (
    select rc.customer_id, m.code, sum(rl.amount) amt
      from receipts rc join receipt_lines rl on rl.receipt_id = rc.id join receipt_modes m on m.id = rl.mode_id
     where rc.org_id = p_org and rc.receipt_date between p_from and p_to
     group by rc.customer_id, m.code),
  r as (select customer_id, jsonb_object_agg(code, amt) by_mode, sum(amt) total from lines group by customer_id),
  ret as (
    select customer_id,
           sum(total) filter (where kind = 'fresh_return')    fr,
           sum(total) filter (where kind = 'rate_difference') rd,
           sum(total) filter (where kind = 'damage_return')   dr,
           sum(total) total
      from sales_returns where org_id = p_org and return_date between p_from and p_to group by customer_id),
  base as (
    select c.id, c.name, c.town, rt.name as route_name,
           c.opening_balance + coalesce(b.amt, 0) - coalesce(pb.amt, 0) - coalesce(rb.amt, 0) as total_outstanding,
           coalesce(r.by_mode, '{}'::jsonb) as by_mode, coalesce(r.total, 0) as received,
           coalesce(ret.fr, 0) fr, coalesce(ret.rd, 0) rd, coalesce(ret.dr, 0) dr, coalesce(ret.total, 0) returned
      from customers c
      left join routes rt on rt.id = c.route_id
      left join billed b on b.customer_id = c.id
      left join paid_before pb on pb.customer_id = c.id
      left join ret_before rb on rb.customer_id = c.id
      left join r on r.customer_id = c.id
      left join ret on ret.customer_id = c.id
     where c.org_id = p_org and (p_route is null or c.route_id = p_route))
  select row_number() over (order by town, name), id, name, town, route_name,
         total_outstanding, by_mode, fr, rd, dr,
         total_outstanding - received - returned
    from base
   where total_outstanding <> 0 or received <> 0 or returned <> 0
   order by town, name;
$$;

-- ------------------------------------------------------------
-- 2. Customer ledger with running balance.
-- ------------------------------------------------------------
create or replace function customer_ledger(p_customer uuid, p_from date default null, p_to date default null)
returns table (
  entry_date date, doc text, doc_no text, doc_id uuid, particulars text,
  debit numeric, credit numeric, balance numeric
) language sql stable as $$
  with c as (select * from customers where id = p_customer),
  docs as (
    select i.invoice_date as d, 'Invoice' as doc, i.invoice_no as doc_no, i.id,
           format('%s boxes · %s', (select coalesce(sum(boxes),0) from invoice_items where invoice_id = i.id), coalesce(i.status::text, '')) as particulars,
           i.total as debit, 0::numeric as credit, 1 as ord
      from invoices i where i.customer_id = p_customer and i.status <> 'cancelled'
    union all
    select r.receipt_date, 'Receipt', r.receipt_no, r.id,
           (select string_agg(m.code || ' ' || rl.amount, ', ') from receipt_lines rl join receipt_modes m on m.id = rl.mode_id where rl.receipt_id = r.id),
           0, r.total_amount, 2
      from receipts r where r.customer_id = p_customer
    union all
    select s.return_date, case s.kind when 'fresh_return' then 'Fresh return' when 'damage_return' then 'Damage return' else 'Rate difference' end,
           s.return_no, s.id, coalesce('against ' || i.invoice_no, ''), 0, s.total, 3
      from sales_returns s left join invoices i on i.id = s.invoice_id where s.customer_id = p_customer),
  opening as (
    select coalesce((select opening_balance from c), 0)
         + coalesce((select sum(debit - credit) from docs where p_from is not null and d < p_from), 0) as bal),
  rows as (
    select null::date as d, 'Opening' as doc, null::text as doc_no, null::uuid as id, 'Opening balance' as particulars,
           case when bal >= 0 then bal else 0 end as debit, case when bal < 0 then -bal else 0 end as credit, 0 as ord, 0::numeric as sortkey
      from opening
    union all
    select d, doc, doc_no, id, particulars, debit, credit, ord, extract(epoch from d)::numeric
      from docs where (p_from is null or d >= p_from) and (p_to is null or d <= p_to))
  select d, doc, doc_no, id, particulars, debit, credit,
         sum(debit - credit) over (order by sortkey, ord, doc_no rows unbounded preceding)
    from rows
   order by sortkey, ord, doc_no;
$$;

-- ------------------------------------------------------------
-- 3. Outstanding ageing 0–15 / 16–30 / 31–60 / 60+ by invoice date.
-- ------------------------------------------------------------
create or replace function outstanding_ageing(p_org uuid, p_as_on date default current_date, p_route uuid default null)
returns table (
  customer_id uuid, name text, town text, route_name text, mobile1 text,
  opening_balance numeric, b0_15 numeric, b16_30 numeric, b31_60 numeric, b60p numeric,
  on_account numeric, outstanding numeric, oldest_days integer
) language sql stable as $$
  with inv as (
    select b.customer_id, b.balance, (p_as_on - b.invoice_date) as age
      from v_invoice_balance b
     where b.org_id = p_org and b.status not in ('draft','cancelled') and b.balance > 0 and b.invoice_date <= p_as_on),
  onacc as (
    select r.customer_id, sum(r.total_amount) - coalesce(sum((select sum(amount) from receipt_allocations a where a.receipt_id = r.id)), 0) as amt
      from receipts r where r.org_id = p_org and r.receipt_date <= p_as_on group by r.customer_id)
  select c.id, c.name, c.town, rt.name, c.mobile1, c.opening_balance,
         coalesce(sum(i.balance) filter (where i.age <= 15), 0),
         coalesce(sum(i.balance) filter (where i.age between 16 and 30), 0),
         coalesce(sum(i.balance) filter (where i.age between 31 and 60), 0),
         coalesce(sum(i.balance) filter (where i.age > 60), 0),
         coalesce(max(o.amt), 0),
         coalesce(max(vo.outstanding), 0),
         max(i.age)::int
    from customers c
    left join routes rt on rt.id = c.route_id
    left join inv i on i.customer_id = c.id
    left join onacc o on o.customer_id = c.id
    left join v_customer_outstanding vo on vo.customer_id = c.id
   where c.org_id = p_org and (p_route is null or c.route_id = p_route)
   group by c.id, c.name, c.town, rt.name, c.mobile1, c.opening_balance
  having coalesce(max(vo.outstanding), 0) <> 0 or count(i.customer_id) > 0
   order by 12 desc;
$$;

-- ------------------------------------------------------------
-- 4. Collection by mode, and route-wise sales & collection.
-- ------------------------------------------------------------
create or replace function collection_by_mode(p_org uuid, p_from date, p_to date, p_route uuid default null)
returns table (mode_id uuid, code text, name text, is_collection boolean, receipts bigint, amount numeric)
language sql stable as $$
  select m.id, m.code, m.name, m.is_collection, count(distinct rc.id), coalesce(sum(rl.amount), 0)
    from receipt_modes m
    left join receipt_lines rl on rl.mode_id = m.id
    left join receipts rc on rc.id = rl.receipt_id and rc.receipt_date between p_from and p_to
         and (p_route is null or exists (select 1 from customers c where c.id = rc.customer_id and c.route_id = p_route))
   where m.org_id = p_org
   group by m.id, m.code, m.name, m.is_collection, m.sort_order
   order by m.sort_order, m.code;
$$;

create or replace function route_collection(p_org uuid, p_from date, p_to date)
returns table (route_id uuid, route_name text, customers bigint, invoices bigint, sales numeric, collected numeric, returned numeric, outstanding numeric)
language sql stable as $$
  select rt.id, coalesce(rt.name, '— no route —'), count(distinct c.id),
         (select count(*) from invoices i where i.org_id = p_org and i.status <> 'cancelled' and i.invoice_date between p_from and p_to and i.customer_id in (select id from customers where org_id = p_org and route_id is not distinct from rt.id)),
         coalesce((select sum(total) from invoices i where i.org_id = p_org and i.status <> 'cancelled' and i.invoice_date between p_from and p_to and i.customer_id in (select id from customers where org_id = p_org and route_id is not distinct from rt.id)), 0),
         coalesce((select sum(total_amount) from receipts r where r.org_id = p_org and r.receipt_date between p_from and p_to and r.customer_id in (select id from customers where org_id = p_org and route_id is not distinct from rt.id)), 0),
         coalesce((select sum(total) from sales_returns s where s.org_id = p_org and s.return_date between p_from and p_to and s.customer_id in (select id from customers where org_id = p_org and route_id is not distinct from rt.id)), 0),
         coalesce(sum(vo.outstanding), 0)
    from customers c
    left join routes rt on rt.id = c.route_id
    left join v_customer_outstanding vo on vo.customer_id = c.id
   where c.org_id = p_org
   group by rt.id, rt.name
   order by 2;
$$;

-- ------------------------------------------------------------
-- 5. Sales summary, grouped any way the client asks.
-- ------------------------------------------------------------
create or replace function sales_summary(p_org uuid, p_from date, p_to date, p_group text default 'day')
returns table (group_key text, group_label text, invoices bigint, boxes numeric, qty numeric, amount numeric)
language sql stable as $$
  with inv as (
    select i.*, c.name as customer_name, c.town, rt.name as route_name
      from invoices i join customers c on c.id = i.customer_id left join routes rt on rt.id = c.route_id
     where i.org_id = p_org and i.status <> 'cancelled' and i.invoice_date between p_from and p_to),
  lines as (
    select inv.*, ii.item_id, ii.boxes as l_boxes, ii.qty as l_qty, ii.amount as l_amount, it.item_code, it.name as item_name, s.name as section_name, s.sort_order as section_sort
      from inv join invoice_items ii on ii.invoice_id = inv.id join items it on it.id = ii.item_id left join sections s on s.id = it.section_id)
  select x.k, x.label, x.n, x.b, x.q, x.a from (
    select case p_group
             when 'day'      then inv.invoice_date::text
             when 'month'    then to_char(inv.invoice_date, 'YYYY-MM')
             when 'customer' then inv.customer_id::text
             when 'town'     then coalesce(inv.town, '')
             when 'route'    then coalesce(inv.route_name, '')
           end as k,
           case p_group
             when 'day'      then to_char(inv.invoice_date, 'DD-MM-YYYY')
             when 'month'    then to_char(inv.invoice_date, 'Mon YYYY')
             when 'customer' then inv.customer_name || coalesce(' — ' || inv.town, '')
             when 'town'     then coalesce(inv.town, '— no town —')
             when 'route'    then coalesce(inv.route_name, '— no route —')
           end as label,
           count(*)::bigint as n,
           coalesce((select sum(boxes) from invoice_items ii where ii.invoice_id = any(array_agg(inv.id))), 0) as b,
           coalesce((select sum(qty)   from invoice_items ii where ii.invoice_id = any(array_agg(inv.id))), 0) as q,
           sum(inv.total) as a
      from inv
     where p_group in ('day','month','customer','town','route')
     group by 1, 2
    union all
    select case p_group when 'item' then l.item_code else coalesce(l.section_name, 'OTHERS') end,
           case p_group when 'item' then l.item_code || ' — ' || l.item_name else coalesce(l.section_name, 'OTHERS') end,
           count(distinct l.id)::bigint, sum(l.l_boxes), sum(l.l_qty), sum(l.l_amount)
      from lines l
     where p_group in ('item','section')
     group by 1, 2
  ) x
  order by case when p_group in ('day','month') then x.k end, x.a desc, x.label;
$$;

-- ------------------------------------------------------------
-- 6. Dashboard: what happened today, one list.
-- ------------------------------------------------------------
create or replace function dashboard_activity(p_org uuid, p_date date default current_date, p_limit int default 30)
returns table (kind text, doc_no text, doc_id uuid, party text, amount numeric, detail text, at timestamptz)
language sql stable as $$
  select x.kind, x.doc_no, x.doc_id, x.party, x.amount, x.detail, x.created_at from (
    select 'Invoice' as kind, i.invoice_no as doc_no, i.id as doc_id, c.name as party, i.total as amount, i.status::text as detail, i.created_at
      from invoices i join customers c on c.id = i.customer_id where i.org_id = p_org and i.invoice_date = p_date
    union all
    select 'Receipt', r.receipt_no, r.id, c.name, r.total_amount, null, r.created_at
      from receipts r join customers c on c.id = r.customer_id where r.org_id = p_org and r.receipt_date = p_date
    union all
    select 'Return', s.return_no, s.id, c.name, s.total, replace(s.kind::text, '_', ' '), s.created_at
      from sales_returns s join customers c on c.id = s.customer_id where s.org_id = p_org and s.return_date = p_date
    union all
    select 'Purchase', p.bill_no, p.id, coalesce(sp.name, 'cash purchase'), p.total, null, p.created_at
      from purchases p left join suppliers sp on sp.id = p.supplier_id where p.org_id = p_org and p.bill_date = p_date
    union all
    select 'Payment', p.payment_no, p.id, coalesce(sp.name, st.full_name, e.name), p.amount, null, p.created_at
      from payments p left join suppliers sp on sp.id = p.supplier_id left join staff st on st.id = p.staff_id left join expense_heads e on e.id = p.expense_head_id
     where p.org_id = p_org and p.payment_date = p_date
    union all
    select 'Batch', b.batch_no, b.id, i.name, b.actual_boxes, b.status::text, b.created_at
      from production_batches b join items i on i.id = b.item_id where b.org_id = p_org and b.production_date = p_date
    union all
    select 'Trip', v.vehicle_number, t.id, coalesce(d.full_name, ''), null::numeric, t.status::text, t.created_at
      from vehicle_trips t join vehicles v on v.id = t.vehicle_id left join staff d on d.id = t.driver_id where t.org_id = p_org and t.trip_date = p_date
  ) x
  order by x.created_at desc
  limit p_limit;
$$;

-- Pending inbound orders (T6 fills them; the dashboard queue exists from now).
create or replace view v_inbound_orders as
select o.id, o.org_id, o.customer_id, c.name as customer_name, c.town as customer_town, c.mobile1,
       o.raw_text, o.audio_url, o.parsed_items, o.source, o.status, o.invoice_id, o.created_at
from inbound_orders o left join customers c on c.id = o.customer_id;
alter view v_inbound_orders set (security_invoker = on);
