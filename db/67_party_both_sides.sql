-- ============================================================
-- JYOTHI FOODS ERP — 67: ONE PARTY, BOTH SIDES OF THE BOOK
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "A single party/customer can act as both a Customer and a Supplier… Net
-- Outstanding = Total Sales − Total Purchases."
--
-- The shop sells to people who also sell to it. Until now those were two
-- unconnected rows — a customer who owed 40,000 and a supplier who was owed
-- 25,000 — and the shop was doing the subtraction on paper, badly, usually
-- while the man was standing there.
--
-- db/50's note said the two ledgers were kept apart on purpose, because
-- "quietly netting them would turn two facts into one number nobody can
-- check". That reasoning still holds and is the reason this does not merge
-- anything. The two ledgers stay exactly as they are, each still correct on
-- its own; what is added is a LINK between the rows and a third figure
-- derived from both, shown beside them rather than instead of them. Sales,
-- purchases and the net are all on the screen at once, so the net can always
-- be taken apart again.
--
--   net_outstanding = what they owe the shop − what the shop owes them
--
-- Positive means they owe; negative means the shop does. Nothing is posted,
-- no journal moves, and unlinking puts everything back exactly as it was: the
-- link is a statement about who two rows are, not an accounting entry.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The link
-- ------------------------------------------------------------
alter table customers
  add column if not exists supplier_id uuid references suppliers(id);

comment on column customers.supplier_id is
  'The same party''s supplier row, when the shop both sells to and buys from them (db/67). Null for everybody else.';

-- One supplier row cannot be two different customers, or the netting would
-- count the same payable twice.
create unique index if not exists customers_supplier_id_key
  on customers (supplier_id) where supplier_id is not null;

/**
 * Tie a customer row and a supplier row together, or untie them with a null
 * supplier. Owner only: it changes what every outstanding figure for that
 * party says, which is not a counter decision.
 */
create or replace function link_party(p_customer uuid, p_supplier uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_cust text; v_sup text;
begin
  if my_role() <> 'owner' then
    raise exception 'Only the owner can tie a customer and a supplier together' using errcode = '42501';
  end if;
  select name into v_cust from customers where id = p_customer and org_id = v_org;
  if v_cust is null then raise exception 'Customer not found'; end if;

  if p_supplier is null then
    update customers set supplier_id = null where id = p_customer and org_id = v_org;
    return format('%s is no longer linked to a supplier', v_cust);
  end if;

  select name into v_sup from suppliers where id = p_supplier and org_id = v_org;
  if v_sup is null then raise exception 'Supplier not found'; end if;

  if exists (select 1 from customers where supplier_id = p_supplier and id <> p_customer and org_id = v_org) then
    raise exception 'That supplier is already linked to another customer. One supplier row belongs to one party.'
      using errcode = '23505';
  end if;

  update customers set supplier_id = p_supplier where id = p_customer and org_id = v_org;
  return format('%s and %s are now one party', v_cust, v_sup);
end $$;

grant execute on function link_party(uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- 2. What the shop owes a supplier, as one figure
-- ------------------------------------------------------------
create or replace function supplier_payable(p_supplier uuid) returns numeric
language sql stable as $$
  select coalesce((select opening_balance from suppliers where id = p_supplier), 0)
       + coalesce((select sum(total)  from purchases        where supplier_id = p_supplier), 0)
       - coalesce((select sum(total)  from purchase_returns where supplier_id = p_supplier), 0)
       - coalesce((select sum(amount) from payments         where supplier_id = p_supplier), 0);
$$;

grant execute on function supplier_payable(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. The customer list carries all three figures
--    A view may only ever have columns APPENDED.
-- ------------------------------------------------------------
drop view if exists v_customer_list cascade;
create or replace view v_customer_list as
select c.id, c.org_id, c.code, c.name, c.mobile1, c.mobile2, c.mobile3, c.town, c.address,
       c.route_id, r.name as route_name, c.price_group, c.credit_limit, c.opening_balance,
       c.whatsapp_opt_in, c.is_active, c.created_at, c.price_list_id,
       coalesce(o.outstanding, 0) as outstanding,
       c.language,
       c.sales_exec_id, se.full_name as sales_exec_name,
       c.payment_promise_on, c.payment_promise_note,
       greatest(0, coalesce(c.opening_balance, 0) - coalesce((
         select sum(ra.amount) from receipt_allocations ra join receipts rc on rc.id = ra.receipt_id
          where rc.customer_id = c.id and ra.invoice_id is null
       ), 0)) as opening_balance_remaining,
       -- db/67: the same party's other side, and the three figures together.
       c.supplier_id,
       sup.name as supplier_name,
       case when c.supplier_id is null then 0 else supplier_payable(c.supplier_id) end as payable,
       coalesce(o.outstanding, 0)
         - case when c.supplier_id is null then 0 else supplier_payable(c.supplier_id) end as net_outstanding
from customers c
left join routes r on r.id = c.route_id
left join staff se on se.id = c.sales_exec_id
left join suppliers sup on sup.id = c.supplier_id
left join v_customer_outstanding o on o.customer_id = c.id;
alter view v_customer_list set (security_invoker = on);
grant select on v_customer_list to authenticated, anon;

-- ------------------------------------------------------------
-- 4. One statement with both sides on it
-- ------------------------------------------------------------
/**
 * Every transaction of a party, whichever side of the book it is on, with a
 * running NET balance. Sales and what the shop collected push the balance up;
 * purchases and what the shop paid push it down.
 *
 * `side` says which ledger each row came from, so the statement can always be
 * read back as the two it is made of.
 */
create or replace function party_statement(
  p_customer uuid, p_from date default null, p_to date default null
) returns table (
  entry_date date, side text, doc text, doc_no text, doc_id uuid, particulars text,
  owes_us numeric, we_owe numeric, balance numeric
) language sql stable as $$
  with c as (select * from customers where id = p_customer),
  sup as (select supplier_id from c),
  docs as (
    -- their side of the book: what they bought from the shop
    select i.invoice_date as d, 'Sales' as side, 'Invoice' as doc, i.invoice_no as doc_no, i.id,
           format('%s boxes', (select coalesce(sum(boxes),0) from invoice_items where invoice_id = i.id)) as particulars,
           i.total as owes_us, 0::numeric as we_owe, 1 as ord
      from invoices i where i.customer_id = p_customer and i.status <> 'cancelled'
    union all
    select r.receipt_date, 'Sales', 'Receipt', r.receipt_no, r.id,
           (select string_agg(m.code || ' ' || rl.amount, ', ')
              from receipt_lines rl join receipt_modes m on m.id = rl.mode_id where rl.receipt_id = r.id),
           -r.total_amount, 0, 2
      from receipts r where r.customer_id = p_customer
    union all
    select s.return_date, 'Sales',
           case s.kind when 'fresh_return' then 'Fresh return' when 'damage_return' then 'Damage return' else 'Rate difference' end,
           s.return_no, s.id, coalesce('against ' || i.invoice_no, ''), -s.total, 0, 3
      from sales_returns s left join invoices i on i.id = s.invoice_id where s.customer_id = p_customer
    union all
    -- the shop's side: what it bought from them
    select p.bill_date, 'Purchases', 'Purchase', p.bill_no, p.id,
           format('%s lines', (select count(*) from purchase_items pi where pi.purchase_id = p.id)),
           0, p.total, 4
      from purchases p where p.supplier_id = (select supplier_id from sup)
    union all
    select pm.payment_date, 'Purchases', 'Payment', pm.payment_no, pm.id,
           coalesce(pm.narration, pm.reference, ''), 0, -pm.amount, 5
      from payments pm where pm.supplier_id = (select supplier_id from sup)
    union all
    select pr.return_date, 'Purchases', 'Purchase return', pr.return_no, pr.id,
           coalesce(pr.notes, ''), 0, -pr.total, 6
      from purchase_returns pr where pr.supplier_id = (select supplier_id from sup)),
  opening as (
    select coalesce((select opening_balance from c), 0)
         - coalesce((select opening_balance from suppliers where id = (select supplier_id from sup)), 0)
         + coalesce((select sum(owes_us - we_owe) from docs where p_from is not null and d < p_from), 0) as bal),
  rows as (
    select null::date as d, 'Opening' as side, 'Opening' as doc, null::text as doc_no, null::uuid as id,
           'Brought forward' as particulars,
           case when bal >= 0 then bal else 0 end as owes_us,
           case when bal < 0 then -bal else 0 end as we_owe,
           0 as ord, 0::numeric as sortkey
      from opening
    union all
    select d, side, doc, doc_no, id, particulars, owes_us, we_owe, ord, extract(epoch from d)::numeric
      from docs where (p_from is null or d >= p_from) and (p_to is null or d <= p_to))
  select d, side, doc, doc_no, id, particulars, owes_us, we_owe,
         sum(owes_us - we_owe) over (order by sortkey, ord, doc_no rows unbounded preceding)
    from rows
   order by sortkey, ord, doc_no;
$$;

grant execute on function party_statement(uuid, date, date) to authenticated;
