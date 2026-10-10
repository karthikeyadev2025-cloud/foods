-- ============================================================
-- JYOTHI FOODS ERP — CONSOLIDATED PENDING MIGRATIONS (53 to 58)
--
-- This file combines all pending migrations into a single, self-contained,
-- fully idempotent script that can be run directly in the Supabase SQL Editor.
--
-- INCLUDES:
--   53: Purchase Edit (reversing stock & journals instead of delete)
--   54: Stock Report (includes Raw Material & Packing Material)
--   55: Document Lines Ordering (preserves typed sequence across 7 documents)
--   56: Numbering Lock Timeout (clean 3-second timeout & diagnostic error)
--   57: Print Letterhead (toggle to hide business name on pre-printed paper)
--   58: Receipt Opening Balance First, Purchase Contact Print & Stock Reversal Date
--   59: the fix that lets 58's purchase reversal run at all
--
-- If 53 to 58 have already been run by hand, this file is not needed — run
-- db/59_purchase_edit_author.sql on its own, which is the only part of it that
-- is new.
-- ============================================================

-- ============================================================
-- SECTION 1: DOCUMENT LINE ORDERING (55)
-- ============================================================

do $$
declare
  spec text[];
  t text;
  fk text;
begin
  foreach spec slice 1 in array array[
    ['invoice_items',        'invoice_id'],
    ['purchase_items',       'purchase_id'],
    ['sales_return_items',   'return_id'],
    ['quotation_items',      'quotation_id'],
    ['order_items',          'order_id'],
    ['challan_items',        'challan_id'],
    ['purchase_return_items','return_id']
  ] loop
    t  := spec[1];
    fk := spec[2];

    execute format('alter table public.%I add column if not exists line_no integer', t);
    execute format('create index if not exists %I on public.%I (%I)', t || '_' || fk || '_idx', t, fk);
  end loop;
end $$;

create or replace function trg_line_no() returns trigger language plpgsql as $$
declare v_col text := tg_argv[0]; v_parent uuid; v_next integer;
begin
  if new.line_no is not null then return new; end if;
  v_parent := (to_jsonb(new) ->> v_col)::uuid;
  execute format('select coalesce(max(line_no), 0) + 1 from public.%I where %I = $1', tg_table_name, v_col)
    into v_next using v_parent;
  new.line_no := v_next;
  return new;
end $$;

do $$
declare
  spec text[];
  t text;
  fk text;
begin
  foreach spec slice 1 in array array[
    ['invoice_items',        'invoice_id'],
    ['purchase_items',       'purchase_id'],
    ['sales_return_items',   'return_id'],
    ['quotation_items',      'quotation_id'],
    ['order_items',          'order_id'],
    ['challan_items',        'challan_id'],
    ['purchase_return_items','return_id']
  ] loop
    t  := spec[1];
    fk := spec[2];
    execute format('drop trigger if exists t_line_no on public.%I', t);
    execute format('create trigger t_line_no before insert on public.%I for each row execute function trg_line_no(%L)', t, fk);
  end loop;
end $$;

drop view if exists v_invoice_lines cascade;
create or replace view v_invoice_lines as
select ii.id, ii.invoice_id, ii.item_id, i.item_code, i.name as item_name, pt.code as pack_code,
       ii.units_per_box, ii.boxes, ii.qty, ii.rate, ii.amount, ii.uom_id, ii.qty_base, ii.line_no
from invoice_items ii
join items i on i.id = ii.item_id
left join pack_types pt on pt.id = i.pack_type_id;
alter view v_invoice_lines set (security_invoker = on);
grant select on v_invoice_lines to authenticated, anon;

drop view if exists v_purchase_lines cascade;
create or replace view v_purchase_lines as
select pi.id, pi.purchase_id, pi.item_id, i.item_code, i.name as item_name, pi.qty, pi.uom_id, u.code as uom_code,
       pi.qty_base, pi.rate, pi.amount, pi.boxes, pi.units_per_box, pi.line_no
from purchase_items pi join items i on i.id = pi.item_id left join uoms u on u.id = pi.uom_id;
alter view v_purchase_lines set (security_invoker = on);
grant select on v_purchase_lines to authenticated, anon;

drop view if exists v_return_lines cascade;
create or replace view v_return_lines as
select ri.id, ri.return_id, ri.item_id, i.item_code, i.name as item_name, i.units_per_box,
       ri.qty, ri.qty / nullif(i.units_per_box, 0) as boxes, ri.uom_id, ri.qty_base, ri.old_rate, ri.new_rate, ri.amount,
       ri.line_no
from sales_return_items ri join items i on i.id = ri.item_id;
alter view v_return_lines set (security_invoker = on);
grant select on v_return_lines to authenticated, anon;

drop view if exists v_quotation_lines cascade;
create or replace view v_quotation_lines as
select qi.id, qi.quotation_id, qi.item_id, i.item_code, i.name as item_name, pt.code as pack_code, qi.units_per_box,
       qi.boxes, qi.qty, qi.rate, qi.amount, qi.uom_id, qi.qty_base, qi.line_no
  from quotation_items qi join items i on i.id = qi.item_id left join pack_types pt on pt.id = i.pack_type_id;
alter view v_quotation_lines set (security_invoker = on);
grant select on v_quotation_lines to authenticated, anon;

drop view if exists v_order_lines cascade;
create or replace view v_order_lines as
select oi.id, oi.order_id, oi.item_id, i.item_code, i.name as item_name, oi.units_per_box, oi.boxes, oi.qty, oi.rate,
       oi.amount, oi.uom_id, oi.qty_base, oi.delivered_base,
       round(oi.delivered_base / nullif(oi.units_per_box, 0), 3) as delivered_boxes,
       round(oi.boxes - oi.delivered_base / nullif(oi.units_per_box, 0), 3) as pending_boxes,
       oi.line_no
  from order_items oi join items i on i.id = oi.item_id;
alter view v_order_lines set (security_invoker = on);
grant select on v_order_lines to authenticated, anon;

drop view if exists v_challan_lines cascade;
create or replace view v_challan_lines as
select ci.id, ci.challan_id, ci.item_id, i.item_code, i.name as item_name, ci.units_per_box, ci.boxes, ci.qty,
       ci.uom_id, ci.qty_base, ci.line_no
  from challan_items ci join items i on i.id = ci.item_id;
alter view v_challan_lines set (security_invoker = on);
grant select on v_challan_lines to authenticated, anon;

drop view if exists v_purchase_return_lines cascade;
create or replace view v_purchase_return_lines as
select ri.id, ri.return_id, ri.item_id, i.item_code, i.name as item_name, ri.qty, ri.uom_id, u.code as uom_code,
       ri.qty_base, ri.rate, ri.amount, ri.line_no
  from purchase_return_items ri join items i on i.id = ri.item_id left join uoms u on u.id = ri.uom_id;
alter view v_purchase_return_lines set (security_invoker = on);
grant select on v_purchase_return_lines to authenticated, anon;


-- ============================================================
-- SECTION 2: STOCK REPORT RAW & PACKING MATERIALS (54)
-- ============================================================

drop function if exists closing_stock_report(uuid, date, uuid, uuid);

create or replace function closing_stock_report(
  p_org uuid, p_date date default current_date, p_location uuid default null, p_section uuid default null
) returns table (
  section_id uuid, section_code text, section_name text, sort_order integer,
  item_id uuid, item_code text, pack text, item_name text, units_per_box integer,
  item_type text,
  opening numeric, purchase numeric, production numeric, sales numeric, other numeric, closing numeric,
  opening_units numeric, closing_units numeric, is_negative boolean
) language sql stable as $$
  select
    case when i.type = 'finished_good' then sec.id end,
    case when i.type = 'finished_good' then sec.code end,
    case i.type
      when 'raw_material'    then 'RAW MATERIAL'
      when 'packing_material' then 'PACKING MATERIAL'
      else coalesce(sec.name, 'OTHERS') end,
    case i.type
      when 'raw_material'    then 1001
      when 'packing_material' then 1002
      else coalesce(sec.sort_order, 999) end,
    i.id, i.item_code, pt.code, i.name, i.units_per_box,
    i.type::text,
    round(coalesce(sum(sl.qty_base) filter (where sl.txn_date < p_date), 0) / upb.n, 3),
    round(coalesce(sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type = 'purchase'), 0) / upb.n, 3),
    round(coalesce(sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type = 'production_in'), 0) / upb.n, 3),
    round(coalesce(-sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type = 'sale'), 0) / upb.n, 3),
    round(coalesce(sum(sl.qty_base) filter (
      where sl.txn_date = p_date and sl.txn_type not in ('purchase', 'production_in', 'sale')), 0)
          / upb.n, 3),
    round(coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date), 0) / upb.n, 3),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <  p_date), 0),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date), 0),
    coalesce(sum(sl.qty_base) filter (where sl.txn_date <= p_date), 0) < 0
  from items i
  cross join lateral (select coalesce(nullif(i.units_per_box, 0), 1)::numeric as n) upb
  left join sections sec on sec.id = i.section_id
  left join pack_types pt on pt.id = i.pack_type_id
  left join stock_ledger sl on sl.item_id = i.id
       and (p_location is null or sl.location_id = p_location)
  where i.org_id = p_org and i.is_active
    and (p_section is null or i.section_id = p_section)
  group by sec.id, sec.code, sec.name, sec.sort_order, i.id, i.item_code, pt.code, i.name,
           i.units_per_box, i.type, upb.n
  order by
    case i.type when 'raw_material' then 1001 when 'packing_material' then 1002
                else coalesce(sec.sort_order, 999) end,
    case i.type
      when 'raw_material'    then 'RAW MATERIAL'
      when 'packing_material' then 'PACKING MATERIAL'
      else coalesce(sec.name, 'OTHERS') end,
    i.item_code;
$$;


-- ============================================================
-- SECTION 3: NUMBERING LOCK TIMEOUT (56)
-- ============================================================

create or replace function next_doc_no(p_org uuid, p_doc_type text)
returns text language plpgsql security definer set search_path = public as $$
declare
  ns      number_series%rowtype;
  v_reset boolean := false;
  h       record;
  v_pre   text;
  v_suf   text;
  v_no    text;
  v_taken boolean;
  tries   int := 0;
begin
  if p_org is distinct from my_org_id() then
    raise exception 'Cannot number documents for another organisation';
  end if;

  set local lock_timeout = '3s';

  begin
    select * into ns from number_series
     where org_id = p_org and doc_type = p_doc_type for update;
  exception when lock_not_available then
    raise exception
      'The % numbering is locked by something else and did not let go. Nothing was saved. If it keeps happening, somebody has a query or a session open on Setup → Numbering — close it, or run db/diagnose.sql to find it.',
      p_doc_type
      using errcode = '55P03';
  end;

  if not found then
    insert into number_series (org_id, doc_type) values (p_org, p_doc_type)
    returning * into ns;
  end if;

  v_reset := case ns.reset_period
    when 'yearly'  then ns.last_reset is null or date_trunc('year', ns.last_reset)  < date_trunc('year', current_date)
    when 'monthly' then ns.last_reset is null or date_trunc('month', ns.last_reset) < date_trunc('month', current_date)
    when 'daily'   then ns.last_reset is null or ns.last_reset < current_date
    else false end;

  if v_reset then
    update number_series set next_number = 1, last_reset = current_date where id = ns.id;
    ns.next_number := 1;
  end if;

  v_pre := doc_no_stamp(ns.prefix);
  v_suf := doc_no_stamp(ns.suffix);

  select * into h from doc_no_home(p_doc_type);

  loop
    v_no := v_pre || lpad(ns.next_number::text, ns.width, '0') || v_suf;

    if h.tbl is null then
      v_taken := false;
    else
      execute format('select exists (select 1 from %I where org_id = $1 and %I = $2)', h.tbl, h.col)
        into v_taken using p_org, v_no;
    end if;

    exit when not v_taken;

    ns.next_number := ns.next_number + 1;
    tries := tries + 1;
    if tries > 100000 then
      raise exception 'Could not find a free % number after % tries — check Setup → Numbering',
        p_doc_type, tries;
    end if;
  end loop;

  update number_series set next_number = ns.next_number + 1, last_reset = current_date
   where id = ns.id;

  return v_no;
end $$;


-- ============================================================
-- SECTION 4: PRE-PRINTED LETTERHEAD SETTING (57)
-- ============================================================

alter table orgs add column if not exists print_org_name boolean not null default true;

comment on column orgs.print_org_name is
  'Print the business name at the top of documents. Off when printing on pre-printed letterhead.';

drop view if exists v_me cascade;
create or replace view v_me as
select s.id as staff_id, s.auth_uid, s.full_name, s.phone, s.role, s.is_mestry, s.is_active,
       o.id as org_id, o.name as org_name, o.address, o.phone as org_phone, o.fssai_no,
       o.breakage_recovery_pct, o.interest_pct_pa, o.credit_days, o.jurisdiction,
       o.license_valid_till,
       o.logo_url, o.signature_url, o.email as org_email, o.tagline, o.bank_details,
       o.print_org_name
from staff s join orgs o on o.id = s.org_id
where s.auth_uid = auth.uid();
alter view v_me set (security_invoker = on);
grant select on v_me to authenticated, anon;


-- ============================================================
-- SECTION 5: RECEIPT OPENING BALANCE & PURCHASE PRINT/EDIT (58)
-- ============================================================

-- 1. Receipt allocations to Opening Balance (invoice_id is nullable)
alter table receipt_allocations alter column invoice_id drop not null;

drop view if exists v_receipt_allocations cascade;
create or replace view v_receipt_allocations as
select a.id, a.receipt_id, a.invoice_id,
       case when a.invoice_id is null then 'OPENING BALANCE' else i.invoice_no end as invoice_no,
       case when a.invoice_id is null then null else i.invoice_date end as invoice_date,
       a.amount
from receipt_allocations a
left join invoices i on i.id = a.invoice_id;
alter view v_receipt_allocations set (security_invoker = on);
grant select on v_receipt_allocations to authenticated, anon;

-- 2. Customer list with opening_balance_remaining and all original columns preserved
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
       ), 0)) as opening_balance_remaining
from customers c
left join routes r on r.id = c.route_id
left join staff se on se.id = c.sales_exec_id
left join v_customer_outstanding o on o.customer_id = c.id;
alter view v_customer_list set (security_invoker = on);
grant select on v_customer_list to authenticated, anon;

-- 3. Outstanding Ageing Report with remaining opening balance
drop function if exists outstanding_ageing(uuid, date, uuid);

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
      from receipts r where r.org_id = p_org and r.receipt_date <= p_as_on group by r.customer_id),
  open_rem as (
    select c.id as customer_id,
           greatest(0, coalesce(c.opening_balance, 0) - coalesce((
             select sum(ra.amount) from receipt_allocations ra join receipts rc on rc.id = ra.receipt_id
              where rc.customer_id = c.id and ra.invoice_id is null and rc.receipt_date <= p_as_on
           ), 0)) as rem
      from customers c where c.org_id = p_org)
  select c.id, c.name, c.town, rt.name, c.mobile1,
         coalesce(orem.rem, coalesce(c.opening_balance, 0)),
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
    left join open_rem orem on orem.customer_id = c.id
    left join v_customer_outstanding vo on vo.customer_id = c.id
   where c.org_id = p_org and (p_route is null or c.route_id = p_route)
   group by c.id, c.name, c.town, rt.name, c.mobile1, c.opening_balance, orem.rem
  having coalesce(max(vo.outstanding), 0) <> 0 or count(i.customer_id) > 0
   order by 12 desc;
$$;

-- 4. save_receipt prioritizing opening balance before invoices
create or replace function save_receipt(p_header jsonb, p_lines jsonb, p_allocations jsonb default '[]'::jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; v_cust uuid; v_date date; v_total numeric := 0; l jsonb; n int := 0;
  m receipt_modes%rowtype; v_remaining numeric; inv record; v_alloc numeric; v_cust_name text; v_no text;
  v_lines jsonb := '[]'::jsonb; v_amt numeric; v_acct uuid; v_ref text; v_line_id uuid;
  v_open_rem numeric; v_inv_id uuid;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A receipt needs at least one mode line';
  end if;
  v_cust := (p_header->>'customer_id')::uuid;
  v_date := coalesce(nullif(p_header->>'receipt_date','')::date, current_date);
  select name into v_cust_name from customers where id = v_cust and org_id = v_org;
  if v_cust_name is null then raise exception 'Customer not found'; end if;

  v_no := next_doc_no(v_org, 'receipt');
  insert into receipts (org_id, receipt_no, customer_id, receipt_date, vehicle_id, trip_id, narration, created_by, account_id)
  values (v_org, v_no, v_cust, v_date, nullif(p_header->>'vehicle_id','')::uuid, nullif(p_header->>'trip_id','')::uuid,
          nullif(p_header->>'narration',''), my_staff_id(), nullif(p_header->>'account_id','')::uuid)
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    select * into m from receipt_modes where id = (l->>'mode_id')::uuid and org_id = v_org;
    if not found then raise exception 'Line %: receipt mode not found', n; end if;
    v_amt := coalesce((l->>'amount')::numeric, 0);
    if v_amt <= 0 then raise exception 'Line % (%): amount must be greater than zero', n, m.code; end if;
    v_ref := nullif(trim(coalesce(l->>'reference','')), '');
    if (m.needs_reference or m.is_cheque) and v_ref is null then
      raise exception 'Line % (%): a % number is required', n, m.code, case when m.is_cheque then 'cheque' else 'reference' end;
    end if;
    insert into receipt_lines (receipt_id, mode_id, amount, reference) values (v_id, m.id, v_amt, v_ref) returning id into v_line_id;
    v_total := v_total + v_amt;

    if not m.is_collection then
      v_lines := v_lines || jsonb_build_object('account', case when upper(m.code) = 'BRK' then 'BREAKAGE' else 'DISCOUNT' end, 'debit', v_amt, 'narration', m.code);
    elsif m.is_cheque then
      insert into cheques (org_id, direction, party_kind, customer_id, cheque_no, cheque_date, bank_name, amount, state, mode_id, ref_table, ref_id, notes)
      values (v_org, 'received', 'customer', v_cust, v_ref, coalesce(nullif(l->>'cheque_date','')::date, v_date), nullif(l->>'bank_name',''),
              v_amt, 'in_hand', m.id, 'receipts', v_id, format('Receipt %s', v_no));
      v_lines := v_lines || jsonb_build_object('account', 'CHEQUES_IN_HAND', 'debit', v_amt, 'narration', m.code || ' ' || v_ref);
    else
      v_acct := money_account(v_org, m.code, m.account_id, coalesce(nullif(l->>'account_id','')::uuid, nullif(p_header->>'account_id','')::uuid));
      perform post_money(v_org, v_acct, v_date, v_amt, format('Receipt %s — %s (%s)', v_no, v_cust_name, m.code), 'receipts', v_id);
      v_lines := v_lines || jsonb_build_object('account', money_code(v_acct), 'debit', v_amt, 'narration', m.code);
    end if;
  end loop;
  update receipts set total_amount = round(v_total, 2) where id = v_id;

  v_remaining := v_total;

  -- What remains of the customer's opening balance
  select greatest(0, coalesce(c.opening_balance, 0) - coalesce((
    select sum(ra.amount) from receipt_allocations ra join receipts rc on rc.id = ra.receipt_id
     where rc.customer_id = v_cust and ra.invoice_id is null
  ), 0)) into v_open_rem
  from customers c where c.id = v_cust and c.org_id = v_org;

  if jsonb_typeof(p_allocations) = 'array' and jsonb_array_length(p_allocations) > 0 then
    for l in select * from jsonb_array_elements(p_allocations) loop
      v_alloc := coalesce((l->>'amount')::numeric, 0);
      if v_alloc <= 0 then continue; end if;
      v_inv_id := nullif(l->>'invoice_id', '')::uuid;

      if v_inv_id is null or coalesce(l->>'is_opening', 'false')::boolean = true then
        if v_alloc > v_open_rem + 0.005 then
          raise exception 'Allocation % to opening balance exceeds remaining opening balance %', v_alloc, v_open_rem;
        end if;
        if v_alloc > v_remaining + 0.005 then raise exception 'Allocations exceed the receipt total'; end if;
        insert into receipt_allocations (receipt_id, invoice_id, amount) values (v_id, null, round(v_alloc, 2));
        v_remaining := v_remaining - v_alloc;
        v_open_rem := greatest(0, v_open_rem - v_alloc);
      else
        select * into inv from v_invoice_balance where invoice_id = v_inv_id and customer_id = v_cust;
        if not found then raise exception 'Allocation to an invoice that is not this customer''s'; end if;
        if inv.status in ('draft','cancelled') then raise exception 'Cannot allocate to a % invoice', inv.status; end if;
        if v_alloc > inv.balance + 0.005 then
          raise exception 'Allocation % to invoice % exceeds its balance %', v_alloc, inv.invoice_no, inv.balance;
        end if;
        if v_alloc > v_remaining + 0.005 then raise exception 'Allocations exceed the receipt total'; end if;
        insert into receipt_allocations (receipt_id, invoice_id, amount) values (v_id, inv.invoice_id, round(v_alloc, 2));
        v_remaining := v_remaining - v_alloc;
      end if;
    end loop;
  else
    -- FIFO: Clear opening balance FIRST before invoices
    if v_open_rem > 0 and v_remaining > 0 then
      v_alloc := least(v_remaining, v_open_rem);
      insert into receipt_allocations (receipt_id, invoice_id, amount) values (v_id, null, round(v_alloc, 2));
      v_remaining := v_remaining - v_alloc;
    end if;

    -- Then allocate against open invoices oldest first
    for inv in
      select * from v_invoice_balance
       where customer_id = v_cust and status not in ('draft','cancelled') and balance > 0
       order by invoice_date, invoice_no
    loop
      exit when v_remaining <= 0;
      v_alloc := least(v_remaining, inv.balance);
      insert into receipt_allocations (receipt_id, invoice_id, amount) values (v_id, inv.invoice_id, round(v_alloc, 2));
      v_remaining := v_remaining - v_alloc;
    end loop;
  end if;

  perform post_journal(v_org, v_date, format('Receipt %s — %s', v_no, v_cust_name), 'receipts', v_id,
    v_lines || jsonb_build_object('account', 'DEBTORS', 'credit', round(v_total, 2)));
  return v_id;
end $$;

-- 5. Supplier address and purchase list view with contact details
alter table suppliers add column if not exists address text;

drop view if exists v_purchase_list cascade;
create or replace view v_purchase_list as
select p.id, p.org_id, p.bill_no, p.bill_date, p.supplier_id, s.name as supplier_name,
       p.location_id, l.name as location_name, p.subtotal, p.other_charges, p.total, p.paid_amount, p.notes,
       p.created_by, p.created_at,
       coalesce((select count(*) from purchase_items pi where pi.purchase_id = p.id), 0) as line_count,
       s.town as supplier_town, s.mobile1 as supplier_mobile, s.address as supplier_address
from purchases p
left join suppliers s on s.id = p.supplier_id
left join stock_locations l on l.id = p.location_id;
alter view v_purchase_list set (security_invoker = on);
grant select on v_purchase_list to authenticated, anon;

-- 6. Purchase stock posting and unposting with proper date reversal
create or replace function post_purchase_stock(p_purchase uuid)
returns void language plpgsql as $$
declare p purchases%rowtype; v_net numeric;
begin
  select * into p from purchases where id = p_purchase;
  if not found then return; end if;

  select coalesce(sum(qty_base), 0) into v_net
    from stock_ledger where ref_table = 'purchases' and ref_id = p_purchase;

  if v_net <> 0 then
    raise exception 'Purchase % is already posted to stock. Corrections are adjustment rows.', p.bill_no;
  end if;

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select p.org_id, pi.item_id, p.location_id, 'purchase', p.bill_date,
         pi.qty_base, pi.rate, 'purchases', p.id, p.created_by
  from purchase_items pi where pi.purchase_id = p_purchase;
end $$;

create or replace function unpost_purchase_stock(p_purchase uuid, p_on date default null)
returns int language plpgsql as $$
declare v_net numeric; n int := 0;
begin
  select coalesce(sum(qty_base), 0) into v_net
    from stock_ledger where ref_table = 'purchases' and ref_id = p_purchase;
  if v_net = 0 then return 0; end if;

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select org_id, item_id, location_id, 'purchase'::stock_txn_type, coalesce(p_on, max(txn_date)),
         -sum(qty_base), max(rate), 'purchases', ref_id,
         -- There is no max() for uuid, and reaching for one here made every
         -- purchase edit fail outright. The correction belongs to whoever is
         -- making it, falling back to the author of the rows being reversed
         -- (db/59).
         coalesce(my_staff_id(), (array_agg(created_by order by id desc))[1])
    from stock_ledger
   where ref_table = 'purchases' and ref_id = p_purchase
   group by org_id, item_id, location_id, ref_id
  having sum(qty_base) <> 0;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function unpost_purchase_stock(uuid, date) to authenticated;

-- 7. Purchase creation and editing
create or replace function save_purchase(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; l jsonb; n int := 0;
  v_sub numeric := 0; v_other numeric; v_paid numeric; v_total numeric; v_supplier text;
  v_boxes numeric; v_qty numeric; v_bill_no text;
  v_edit boolean; v_before jsonb; k text;
  v_item uuid; v_locn uuid; v_bal numeric; v_was numeric; v_now numeric; v_short text;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A purchase needs at least one line';
  end if;
  v_other := coalesce(nullif(p_header->>'other_charges','')::numeric, 0);
  v_paid  := coalesce(nullif(p_header->>'paid_amount','')::numeric, 0);
  v_id    := nullif(p_header->>'id', '')::uuid;
  v_edit  := v_id is not null;

  if v_edit then
    select bill_no into v_bill_no from purchases where id = v_id and org_id = v_org;
    if v_bill_no is null then raise exception 'Purchase not found'; end if;

    if exists (select 1 from purchase_returns where purchase_id = v_id) then
      raise exception 'Purchase % has a return against it. Delete the return first.', v_bill_no
        using errcode = '23503';
    end if;

    select coalesce(jsonb_object_agg(key, val), '{}'::jsonb) into v_before
      from (select item_id::text || '|' || location_id::text as key, sum(qty_base) as val
              from stock_ledger
             where ref_table = 'purchases' and ref_id = v_id
             group by 1) s;

    perform unpost_purchase_stock(v_id);
    perform reverse_journal(v_org, 'purchases', v_id,
                            (select bill_date from purchases where id = v_id),
                            format('Purchase %s corrected', v_bill_no));

    update purchases set
      bill_no       = coalesce(nullif(trim(p_header->>'bill_no'), ''), bill_no),
      supplier_id   = nullif(p_header->>'supplier_id','')::uuid,
      location_id   = (p_header->>'location_id')::uuid,
      bill_date     = coalesce(nullif(p_header->>'bill_date','')::date, bill_date),
      other_charges = v_other,
      paid_amount   = v_paid,
      notes         = nullif(p_header->>'notes','')
    where id = v_id and org_id = v_org
    returning bill_no into v_bill_no;

    delete from purchase_items where purchase_id = v_id;
  else
    v_bill_no := coalesce(nullif(trim(p_header->>'bill_no'), ''), next_doc_no(v_org, 'purchase'));
    insert into purchases (org_id, bill_no, supplier_id, location_id, bill_date, other_charges, paid_amount, notes, created_by)
    values (v_org, v_bill_no, nullif(p_header->>'supplier_id','')::uuid,
            (p_header->>'location_id')::uuid,
            coalesce(nullif(p_header->>'bill_date','')::date, current_date),
            v_other, v_paid, nullif(p_header->>'notes',''), my_staff_id())
    returning id into v_id;
  end if;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    v_boxes := nullif(l->>'boxes', '')::numeric;
    v_qty   := nullif(l->>'qty', '')::numeric;
    if coalesce(v_boxes, v_qty, 0) <= 0 then
      raise exception 'Line %: quantity must be greater than zero', n;
    end if;

    insert into purchase_items (purchase_id, item_id, boxes, qty, uom_id, qty_base, rate, amount)
    values (v_id, (l->>'item_id')::uuid, v_boxes, coalesce(v_qty, 0),
            nullif(l->>'uom_id','')::uuid, 0,
            coalesce(nullif(l->>'rate','')::numeric, 0), 0);
  end loop;

  select coalesce(sum(amount), 0) into v_sub from purchase_items where purchase_id = v_id;

  v_total := round(v_sub + v_other, 2);
  if v_paid > v_total then raise exception 'Paid amount % exceeds the bill total %', v_paid, v_total; end if;
  update purchases set subtotal = v_sub, total = v_total where id = v_id;

  perform post_purchase_stock(v_id);

  if v_edit then
    for k in
      select key from jsonb_object_keys(v_before) as key
      union
      select item_id::text || '|' || location_id::text
        from stock_ledger where ref_table = 'purchases' and ref_id = v_id
    loop
      v_item := split_part(k, '|', 1)::uuid;
      v_locn := split_part(k, '|', 2)::uuid;

      select coalesce(sum(qty_base), 0) into v_bal
        from stock_ledger where item_id = v_item and location_id = v_locn;
      if v_bal >= 0 then continue; end if;

      v_was := coalesce((v_before->>k)::numeric, 0);
      select coalesce(sum(qty_base), 0) into v_now
        from stock_ledger
       where ref_table = 'purchases' and ref_id = v_id
         and item_id = v_item and location_id = v_locn;

      if v_bal - (v_now - v_was) >= 0 then
        select name into v_short from items where id = v_item;
        raise exception 'Purchase % cannot be changed this way — the goods have already gone out, and it would leave less than nothing of "%". Reverse the bills that used them first.', v_bill_no, v_short
          using errcode = '23514';
      end if;
    end loop;
  end if;

  select name into v_supplier from suppliers where id = nullif(p_header->>'supplier_id','')::uuid;
  perform post_journal(v_org, coalesce(nullif(p_header->>'bill_date','')::date, current_date),
    format('Purchase %s — %s', v_bill_no, coalesce(v_supplier, 'cash purchase')), 'purchases', v_id,
    jsonb_build_array(
      jsonb_build_object('account','PURCHASES', 'debit',  v_total),
      jsonb_build_object('account','CREDITORS', 'credit', v_total),
      jsonb_build_object('account','CREDITORS', 'debit',  v_paid),
      jsonb_build_object('account','CASH',      'credit', v_paid)));
  return v_id;
end $$;
