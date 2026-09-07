-- ============================================================
-- JYOTHI FOODS ERP — 09: TRANSACTIONS (T2)
-- Invoices, purchases, returns, receipts, payments — each saved
-- atomically through one RPC that numbers the document, posts
-- stock through the 05 posting functions, and writes a balanced
-- journal entry (rule 11: money posts to the journal, always).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Invoice header, exactly as the client's quotation form.
-- ------------------------------------------------------------
alter table invoices add column if not exists transport_name text;
alter table invoices add column if not exists lr_no text;
alter table invoices add column if not exists lr_date date;
alter table invoices add column if not exists freight numeric(12,2) not null default 0;

create or replace function recompute_invoice_totals(p_invoice uuid)
returns void language sql as $$
  update invoices i
     set subtotal = s.amt,
         total    = round(s.amt - i.discount + i.freight + i.round_off, 2)
    from (select coalesce(sum(amount), 0) as amt from invoice_items where invoice_id = p_invoice) s
   where i.id = p_invoice;
$$;

create or replace function trg_invoice_total() returns trigger language plpgsql as $$
begin
  new.total := round(new.subtotal - new.discount + new.freight + new.round_off, 2);
  return new;
end $$;

drop trigger if exists t_invoice_total on invoices;
create trigger t_invoice_total before insert or update of subtotal, discount, freight, round_off on invoices
  for each row execute function trg_invoice_total();

-- ------------------------------------------------------------
-- 2. Journal. System accounts are rows the owner can rename but
--    not delete; documents post to them by code.
-- ------------------------------------------------------------
create unique index if not exists ledger_accounts_org_code_uniq on ledger_accounts (org_id, code) where code is not null;
alter table journal_entries add column if not exists reverses_entry_id uuid references journal_entries(id);

create or replace function ensure_system_accounts(p_org uuid)
returns void language sql as $$
  insert into ledger_accounts (org_id, code, name, type, is_system)
  values
    (p_org, 'CASH',          'Cash in hand',              'asset',     true),
    (p_org, 'BANK',          'Bank',                      'asset',     true),
    (p_org, 'DEBTORS',       'Sundry debtors',            'asset',     true),
    (p_org, 'CREDITORS',     'Sundry creditors',          'liability', true),
    (p_org, 'SALES',         'Sales',                     'income',    true),
    (p_org, 'FREIGHT',       'Freight recovered',         'income',    true),
    (p_org, 'ROUND_OFF',     'Round off',                 'income',    true),
    (p_org, 'SALES_RETURNS', 'Sales returns',             'income',    true),
    (p_org, 'RATE_DIFF',     'Rate difference allowed',   'income',    true),
    (p_org, 'DISCOUNT',      'Discount allowed',          'expense',   true),
    (p_org, 'BREAKAGE',      'Breakage / damage',         'expense',   true),
    (p_org, 'PURCHASES',     'Purchases',                 'expense',   true),
    (p_org, 'WAGES',         'Labour & wages',            'expense',   true),
    (p_org, 'EXPENSES',      'General expenses',          'expense',   true)
  on conflict (org_id, name) do nothing;
$$;

create or replace function acct(p_org uuid, p_code text) returns uuid
language sql stable as $$
  select id from ledger_accounts where org_id = p_org and code = p_code;
$$;

-- p_lines: [{"account":"SALES","debit":0,"credit":100}, …]  (codes, not ids)
create or replace function post_journal(
  p_org uuid, p_date date, p_narration text, p_ref_table text, p_ref_id uuid, p_lines jsonb
) returns uuid language plpgsql as $$
declare v_entry uuid; v_dr numeric := 0; v_cr numeric := 0; l jsonb; v_acct uuid;
begin
  perform ensure_system_accounts(p_org);
  select coalesce(sum((x->>'debit')::numeric), 0), coalesce(sum((x->>'credit')::numeric), 0)
    into v_dr, v_cr from jsonb_array_elements(p_lines) x;
  if abs(v_dr - v_cr) > 0.005 then
    raise exception 'Journal does not balance: debit % vs credit %', v_dr, v_cr;
  end if;
  if v_dr = 0 then return null; end if;

  insert into journal_entries (org_id, entry_no, entry_date, narration, ref_table, ref_id, created_by)
  values (p_org, next_doc_no(p_org, 'journal'), p_date, p_narration, p_ref_table, p_ref_id, my_staff_id())
  returning id into v_entry;

  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'debit')::numeric, 0) = 0 and coalesce((l->>'credit')::numeric, 0) = 0 then continue; end if;
    v_acct := acct(p_org, l->>'account');
    if v_acct is null then raise exception 'Unknown ledger account code %', l->>'account'; end if;
    insert into journal_lines (entry_id, account_id, debit, credit, narration)
    values (v_entry, v_acct, round(coalesce((l->>'debit')::numeric, 0), 2), round(coalesce((l->>'credit')::numeric, 0), 2), l->>'narration');
  end loop;
  return v_entry;
end $$;

-- Corrections are reversing entries, never deletes.
create or replace function reverse_journal(p_org uuid, p_ref_table text, p_ref_id uuid, p_date date, p_narration text)
returns int language plpgsql as $$
declare e record; v_new uuid; n int := 0;
begin
  for e in
    select je.* from journal_entries je
     where je.org_id = p_org and je.ref_table = p_ref_table and je.ref_id = p_ref_id
       and je.reverses_entry_id is null
       and not exists (select 1 from journal_entries r where r.reverses_entry_id = je.id)
  loop
    insert into journal_entries (org_id, entry_no, entry_date, narration, ref_table, ref_id, reverses_entry_id, created_by)
    values (p_org, next_doc_no(p_org, 'journal'), p_date, p_narration, p_ref_table, p_ref_id, e.id, my_staff_id())
    returning id into v_new;
    insert into journal_lines (entry_id, account_id, debit, credit, narration)
    select v_new, account_id, credit, debit, narration from journal_lines where entry_id = e.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ------------------------------------------------------------
-- 3. Invoices
-- ------------------------------------------------------------
create or replace view v_invoice_balance as
select i.id as invoice_id, i.org_id, i.customer_id, i.invoice_date, i.invoice_no, i.status, i.total,
       coalesce((select sum(a.amount) from receipt_allocations a where a.invoice_id = i.id), 0) as received,
       coalesce((select sum(r.total) from sales_returns r where r.invoice_id = i.id), 0) as returned,
       i.total
       - coalesce((select sum(a.amount) from receipt_allocations a where a.invoice_id = i.id), 0)
       - coalesce((select sum(r.total) from sales_returns r where r.invoice_id = i.id), 0) as balance
from invoices i;
alter view v_invoice_balance set (security_invoker = on);

create or replace view v_invoice_list as
select i.id, i.org_id, i.invoice_no, i.invoice_date, i.status, i.customer_id,
       c.name as customer_name, c.town as customer_town, c.mobile1 as customer_mobile,
       i.location_id, l.name as location_name, i.vehicle_id, v.vehicle_number, i.trip_id,
       i.transport_name, i.lr_no, i.lr_date, i.freight, i.discount, i.round_off, i.subtotal, i.total, i.notes,
       i.created_by, i.created_at,
       coalesce((select sum(boxes) from invoice_items ii where ii.invoice_id = i.id), 0) as total_boxes,
       coalesce((select sum(qty)   from invoice_items ii where ii.invoice_id = i.id), 0) as total_qty,
       coalesce((select count(*)   from invoice_items ii where ii.invoice_id = i.id), 0) as line_count,
       b.received, b.returned, b.balance
from invoices i
join customers c on c.id = i.customer_id
left join stock_locations l on l.id = i.location_id
left join vehicles v on v.id = i.vehicle_id
left join v_invoice_balance b on b.invoice_id = i.id;
alter view v_invoice_list set (security_invoker = on);

-- Lines with the item joined — the screen and the print both read this.
create or replace view v_invoice_lines as
select ii.id, ii.invoice_id, ii.item_id, i.item_code, i.name as item_name, pt.code as pack_code,
       ii.units_per_box, ii.boxes, ii.qty, ii.rate, ii.amount, ii.uom_id, ii.qty_base
from invoice_items ii
join items i on i.id = ii.item_id
left join pack_types pt on pt.id = i.pack_type_id;
alter view v_invoice_lines set (security_invoker = on);

-- Save (draft) header + lines in one call. The operator typed CODE, Boxes,
-- Rate per line; packing and defaults come from the master via the triggers.
create or replace function save_invoice(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p_header->>'id', '')::uuid; v_status invoice_status; l jsonb; n int := 0;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'An invoice needs at least one line';
  end if;

  if v_id is null then
    insert into invoices (org_id, invoice_no, customer_id, invoice_date, location_id, vehicle_id,
                          transport_name, lr_no, lr_date, freight, discount, round_off, notes, created_by)
    values (v_org, next_doc_no(v_org, 'invoice'),
            (p_header->>'customer_id')::uuid,
            coalesce(nullif(p_header->>'invoice_date','')::date, current_date),
            (p_header->>'location_id')::uuid,
            nullif(p_header->>'vehicle_id','')::uuid,
            nullif(p_header->>'transport_name',''), nullif(p_header->>'lr_no',''),
            nullif(p_header->>'lr_date','')::date,
            coalesce(nullif(p_header->>'freight','')::numeric, 0),
            coalesce(nullif(p_header->>'discount','')::numeric, 0),
            coalesce(nullif(p_header->>'round_off','')::numeric, 0),
            nullif(p_header->>'notes',''), my_staff_id())
    returning id into v_id;
  else
    select status into v_status from invoices where id = v_id and org_id = v_org;
    if v_status is null then raise exception 'Invoice not found'; end if;
    if v_status <> 'draft' then raise exception 'Invoice is %; only drafts can be edited', v_status; end if;
    update invoices set
      customer_id    = (p_header->>'customer_id')::uuid,
      invoice_date   = coalesce(nullif(p_header->>'invoice_date','')::date, invoice_date),
      location_id    = (p_header->>'location_id')::uuid,
      vehicle_id     = nullif(p_header->>'vehicle_id','')::uuid,
      transport_name = nullif(p_header->>'transport_name',''),
      lr_no          = nullif(p_header->>'lr_no',''),
      lr_date        = nullif(p_header->>'lr_date','')::date,
      freight        = coalesce(nullif(p_header->>'freight','')::numeric, 0),
      discount       = coalesce(nullif(p_header->>'discount','')::numeric, 0),
      round_off      = coalesce(nullif(p_header->>'round_off','')::numeric, 0),
      notes          = nullif(p_header->>'notes','')
    where id = v_id;
    delete from invoice_items where invoice_id = v_id;
  end if;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    if coalesce((l->>'boxes')::numeric, 0) <= 0 then
      raise exception 'Line %: boxes must be greater than zero', n;
    end if;
    insert into invoice_items (invoice_id, item_id, boxes, rate)
    values (v_id, (l->>'item_id')::uuid, (l->>'boxes')::numeric, nullif(l->>'rate','')::numeric);
  end loop;
  return v_id;
end $$;

-- Status machine. Stock posts via the 05 trigger; money posts here.
create or replace function set_invoice_status(p_invoice uuid, p_status invoice_status)
returns void language plpgsql as $$
declare inv invoices%rowtype; v_cust text; v_alloc numeric;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found'; end if;
  if inv.status = p_status then return; end if;

  if not (
       (inv.status = 'draft'      and p_status in ('confirmed','cancelled'))
    or (inv.status = 'confirmed'  and p_status in ('dispatched','delivered','cancelled'))
    or (inv.status = 'dispatched' and p_status in ('delivered','cancelled'))
  ) then
    raise exception 'Cannot move invoice % from % to %', inv.invoice_no, inv.status, p_status;
  end if;

  if p_status = 'confirmed' and not exists (select 1 from invoice_items where invoice_id = p_invoice) then
    raise exception 'Invoice % has no lines', inv.invoice_no;
  end if;

  if p_status = 'cancelled' then
    select coalesce(sum(amount), 0) into v_alloc from receipt_allocations where invoice_id = p_invoice;
    if v_alloc > 0 then
      raise exception 'Invoice % has receipts allocated against it (%). Reverse those first.', inv.invoice_no, v_alloc;
    end if;
    if exists (select 1 from sales_returns where invoice_id = p_invoice) then
      raise exception 'Invoice % has returns against it. Cancel those first.', inv.invoice_no;
    end if;
  end if;

  update invoices set status = p_status where id = p_invoice;   -- 05 trigger posts / reverses stock

  select name into v_cust from customers where id = inv.customer_id;
  if p_status = 'confirmed' then
    perform post_journal(inv.org_id, inv.invoice_date, format('Invoice %s — %s', inv.invoice_no, v_cust), 'invoices', inv.id,
      jsonb_build_array(
        jsonb_build_object('account','DEBTORS',   'debit',  inv.total),
        jsonb_build_object('account','DISCOUNT',  'debit',  inv.discount),
        jsonb_build_object('account','ROUND_OFF', 'debit',  greatest(-inv.round_off, 0)),
        jsonb_build_object('account','SALES',     'credit', inv.subtotal),
        jsonb_build_object('account','FREIGHT',   'credit', inv.freight),
        jsonb_build_object('account','ROUND_OFF', 'credit', greatest(inv.round_off, 0))));
  elsif p_status = 'cancelled' and inv.status in ('confirmed','dispatched') then
    perform reverse_journal(inv.org_id, 'invoices', inv.id, current_date, format('Cancelled invoice %s', inv.invoice_no));
  end if;
end $$;

-- ------------------------------------------------------------
-- 4. Purchases: stock in on save, Dr Purchases / Cr Creditors,
--    any amount paid on the spot Dr Creditors / Cr Cash.
-- ------------------------------------------------------------
create or replace view v_purchase_list as
select p.id, p.org_id, p.bill_no, p.bill_date, p.supplier_id, s.name as supplier_name,
       p.location_id, l.name as location_name, p.subtotal, p.other_charges, p.total, p.paid_amount, p.notes,
       p.created_by, p.created_at,
       coalesce((select count(*) from purchase_items pi where pi.purchase_id = p.id), 0) as line_count
from purchases p
left join suppliers s on s.id = p.supplier_id
left join stock_locations l on l.id = p.location_id;
alter view v_purchase_list set (security_invoker = on);

create or replace view v_purchase_lines as
select pi.id, pi.purchase_id, pi.item_id, i.item_code, i.name as item_name, pi.qty, pi.uom_id, u.code as uom_code,
       pi.qty_base, pi.rate, pi.amount
from purchase_items pi join items i on i.id = pi.item_id left join uoms u on u.id = pi.uom_id;
alter view v_purchase_lines set (security_invoker = on);

create or replace function save_purchase(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid; l jsonb; n int := 0; v_sub numeric := 0; v_other numeric; v_paid numeric; v_total numeric; v_supplier text;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A purchase needs at least one line';
  end if;
  v_other := coalesce(nullif(p_header->>'other_charges','')::numeric, 0);
  v_paid  := coalesce(nullif(p_header->>'paid_amount','')::numeric, 0);

  insert into purchases (org_id, bill_no, supplier_id, location_id, bill_date, other_charges, paid_amount, notes, created_by)
  values (v_org, nullif(p_header->>'bill_no',''), nullif(p_header->>'supplier_id','')::uuid,
          (p_header->>'location_id')::uuid,
          coalesce(nullif(p_header->>'bill_date','')::date, current_date),
          v_other, v_paid, nullif(p_header->>'notes',''), my_staff_id())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    if coalesce((l->>'qty')::numeric, 0) <= 0 then raise exception 'Line %: quantity must be greater than zero', n; end if;
    insert into purchase_items (purchase_id, item_id, qty, uom_id, qty_base, rate, amount)
    values (v_id, (l->>'item_id')::uuid, (l->>'qty')::numeric, (l->>'uom_id')::uuid, 0,
            coalesce(nullif(l->>'rate','')::numeric, 0),
            round((l->>'qty')::numeric * coalesce(nullif(l->>'rate','')::numeric, 0), 2));
    v_sub := v_sub + round((l->>'qty')::numeric * coalesce(nullif(l->>'rate','')::numeric, 0), 2);
  end loop;

  v_total := round(v_sub + v_other, 2);
  if v_paid > v_total then raise exception 'Paid amount % exceeds the bill total %', v_paid, v_total; end if;
  update purchases set subtotal = v_sub, total = v_total where id = v_id;

  perform post_purchase_stock(v_id);

  select name into v_supplier from suppliers where id = nullif(p_header->>'supplier_id','')::uuid;
  perform post_journal(v_org, coalesce(nullif(p_header->>'bill_date','')::date, current_date),
    format('Purchase %s — %s', coalesce(p_header->>'bill_no', ''), coalesce(v_supplier, 'cash purchase')), 'purchases', v_id,
    jsonb_build_array(
      jsonb_build_object('account','PURCHASES', 'debit',  v_total),
      jsonb_build_object('account','CREDITORS', 'credit', v_total),
      jsonb_build_object('account','CREDITORS', 'debit',  v_paid),
      jsonb_build_object('account','CASH',      'credit', v_paid)));
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 5. Sales returns: three kinds, deliberately separated.
-- ------------------------------------------------------------
create or replace view v_return_list as
select r.id, r.org_id, r.return_no, r.return_date, r.kind, r.customer_id, c.name as customer_name, c.town as customer_town,
       r.invoice_id, i.invoice_no, r.location_id, l.name as location_name, r.total, r.notes, r.created_by, r.created_at,
       coalesce((select count(*) from sales_return_items ri where ri.return_id = r.id), 0) as line_count
from sales_returns r
join customers c on c.id = r.customer_id
left join invoices i on i.id = r.invoice_id
left join stock_locations l on l.id = r.location_id;
alter view v_return_list set (security_invoker = on);

create or replace view v_return_lines as
select ri.id, ri.return_id, ri.item_id, i.item_code, i.name as item_name, i.units_per_box,
       ri.qty, ri.qty / nullif(i.units_per_box, 0) as boxes, ri.uom_id, ri.qty_base, ri.old_rate, ri.new_rate, ri.amount
from sales_return_items ri join items i on i.id = ri.item_id;
alter view v_return_lines set (security_invoker = on);

-- Lines: [{item_id, boxes, rate, new_rate}]. rate is the billed unit rate.
--   fresh_return    credit = qty × rate,                  stock back in
--   damage_return   credit = qty × rate × breakage %,     stock written off
--   rate_difference credit = qty × (rate − new_rate),     NO stock row
create or replace function save_sales_return(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; v_kind return_kind; v_loc uuid; v_inv uuid; v_cust uuid;
  l jsonb; n int := 0; it items%rowtype; v_qty numeric; v_amt numeric; v_total numeric := 0; v_rate numeric; v_new numeric;
  v_pct numeric; v_cust_name text; v_no text; v_date date;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A return needs at least one line';
  end if;
  v_kind := (p_header->>'kind')::return_kind;
  v_cust := (p_header->>'customer_id')::uuid;
  v_inv  := nullif(p_header->>'invoice_id','')::uuid;
  v_loc  := nullif(p_header->>'location_id','')::uuid;
  v_date := coalesce(nullif(p_header->>'return_date','')::date, current_date);

  if v_kind = 'rate_difference' then
    v_loc := null;                                   -- never a stock movement
  elsif v_loc is null then
    raise exception 'A % needs the location the goods came back to', v_kind;
  end if;
  if v_inv is not null and not exists (select 1 from invoices where id = v_inv and customer_id = v_cust) then
    raise exception 'That invoice does not belong to this customer';
  end if;
  select breakage_recovery_pct into v_pct from orgs where id = v_org;

  v_no := next_doc_no(v_org, 'return');
  insert into sales_returns (org_id, return_no, customer_id, invoice_id, return_date, kind, location_id, notes, created_by)
  values (v_org, v_no, v_cust, v_inv, v_date, v_kind, v_loc, nullif(p_header->>'notes',''), my_staff_id())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    select * into it from items where id = (l->>'item_id')::uuid and org_id = v_org;
    if not found then raise exception 'Line %: item not found', n; end if;
    if coalesce((l->>'boxes')::numeric, 0) <= 0 then raise exception 'Line %: boxes must be greater than zero', n; end if;
    v_qty  := round((l->>'boxes')::numeric * it.units_per_box, 3);      -- boxes → units, item's own packing
    v_rate := coalesce(nullif(l->>'rate','')::numeric, it.unit_rate);
    v_new  := nullif(l->>'new_rate','')::numeric;
    v_amt := case v_kind
      when 'fresh_return'    then round(v_qty * v_rate, 2)
      when 'damage_return'   then round(v_qty * v_rate * v_pct / 100, 2)
      when 'rate_difference' then round(v_qty * (v_rate - coalesce(v_new, v_rate)), 2)
    end;
    if v_kind = 'rate_difference' and v_new is null then
      raise exception 'Line %: a rate difference needs the new rate', n;
    end if;
    insert into sales_return_items (return_id, item_id, qty, uom_id, old_rate, new_rate, amount)
    values (v_id, it.id, v_qty, it.base_uom_id, v_rate, v_new, v_amt);
    v_total := v_total + v_amt;
  end loop;

  update sales_returns set total = round(v_total, 2) where id = v_id;
  perform post_return_stock(v_id);

  select name into v_cust_name from customers where id = v_cust;
  perform post_journal(v_org, v_date, format('%s %s — %s', replace(v_kind::text, '_', ' '), v_no, v_cust_name), 'sales_returns', v_id,
    jsonb_build_array(
      jsonb_build_object('account', case v_kind when 'fresh_return' then 'SALES_RETURNS'
                                                 when 'damage_return' then 'BREAKAGE'
                                                 else 'RATE_DIFF' end, 'debit', round(v_total, 2)),
      jsonb_build_object('account', 'DEBTORS', 'credit', round(v_total, 2))));
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 6. Receipts: mode lines + allocation against open invoices.
-- ------------------------------------------------------------
create or replace view v_receipt_list as
select r.id, r.org_id, r.receipt_no, r.receipt_date, r.customer_id, c.name as customer_name, c.town as customer_town,
       r.vehicle_id, r.trip_id, r.total_amount, r.narration, r.created_by, r.created_at,
       (select string_agg(m.code || ' ' || to_char(rl.amount, 'FM999999990.00'), ', ' order by m.sort_order)
          from receipt_lines rl join receipt_modes m on m.id = rl.mode_id where rl.receipt_id = r.id) as modes,
       coalesce((select sum(a.amount) from receipt_allocations a where a.receipt_id = r.id), 0) as allocated
from receipts r join customers c on c.id = r.customer_id;
alter view v_receipt_list set (security_invoker = on);

create or replace view v_receipt_lines as
select rl.id, rl.receipt_id, rl.mode_id, m.code as mode_code, m.name as mode_name, m.is_collection, rl.amount, rl.reference
from receipt_lines rl join receipt_modes m on m.id = rl.mode_id;
alter view v_receipt_lines set (security_invoker = on);

create or replace view v_receipt_allocations as
select a.id, a.receipt_id, a.invoice_id, i.invoice_no, i.invoice_date, a.amount
from receipt_allocations a join invoices i on i.id = a.invoice_id;
alter view v_receipt_allocations set (security_invoker = on);

-- p_lines: [{mode_id, amount, reference}]  p_allocations: [{invoice_id, amount}] or [] for FIFO
create or replace function save_receipt(p_header jsonb, p_lines jsonb, p_allocations jsonb default '[]'::jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; v_cust uuid; v_date date; v_total numeric := 0; l jsonb; n int := 0;
  m receipt_modes%rowtype; v_remaining numeric; inv record; v_alloc numeric; v_cust_name text; v_no text;
  v_lines jsonb := '[]'::jsonb; v_amt numeric;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A receipt needs at least one mode line';
  end if;
  v_cust := (p_header->>'customer_id')::uuid;
  v_date := coalesce(nullif(p_header->>'receipt_date','')::date, current_date);

  v_no := next_doc_no(v_org, 'receipt');
  insert into receipts (org_id, receipt_no, customer_id, receipt_date, vehicle_id, trip_id, narration, created_by)
  values (v_org, v_no, v_cust, v_date, nullif(p_header->>'vehicle_id','')::uuid, nullif(p_header->>'trip_id','')::uuid,
          nullif(p_header->>'narration',''), my_staff_id())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    select * into m from receipt_modes where id = (l->>'mode_id')::uuid and org_id = v_org;
    if not found then raise exception 'Line %: receipt mode not found', n; end if;
    v_amt := coalesce((l->>'amount')::numeric, 0);
    if v_amt <= 0 then raise exception 'Line % (%): amount must be greater than zero', n, m.code; end if;
    if m.needs_reference and nullif(trim(coalesce(l->>'reference','')), '') is null then
      raise exception 'Line % (%): a reference number is required', n, m.code;
    end if;
    insert into receipt_lines (receipt_id, mode_id, amount, reference)
    values (v_id, m.id, v_amt, nullif(trim(coalesce(l->>'reference','')), ''));
    v_total := v_total + v_amt;
    -- money in → cash/bank; a deduction head (BRK, ADJ) → its expense
    v_lines := v_lines || jsonb_build_object(
      'account', case when m.is_collection then (case when upper(m.code) = 'CASH' then 'CASH' else 'BANK' end)
                      else (case when upper(m.code) = 'BRK' then 'BREAKAGE' else 'DISCOUNT' end) end,
      'debit', v_amt, 'narration', m.code);
  end loop;
  update receipts set total_amount = round(v_total, 2) where id = v_id;

  -- Allocation: explicit, or FIFO over the customer's open invoices.
  v_remaining := v_total;
  if jsonb_typeof(p_allocations) = 'array' and jsonb_array_length(p_allocations) > 0 then
    for l in select * from jsonb_array_elements(p_allocations) loop
      v_alloc := coalesce((l->>'amount')::numeric, 0);
      if v_alloc <= 0 then continue; end if;
      select * into inv from v_invoice_balance where invoice_id = (l->>'invoice_id')::uuid and customer_id = v_cust;
      if not found then raise exception 'Allocation to an invoice that is not this customer''s'; end if;
      if inv.status in ('draft','cancelled') then raise exception 'Cannot allocate to a % invoice', inv.status; end if;
      if v_alloc > inv.balance + 0.005 then
        raise exception 'Allocation % to invoice % exceeds its balance %', v_alloc, inv.invoice_no, inv.balance;
      end if;
      if v_alloc > v_remaining + 0.005 then
        raise exception 'Allocations exceed the receipt total';
      end if;
      insert into receipt_allocations (receipt_id, invoice_id, amount) values (v_id, inv.invoice_id, round(v_alloc, 2));
      v_remaining := v_remaining - v_alloc;
    end loop;
  else
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
    -- anything left stays on account as an advance
  end if;

  select name into v_cust_name from customers where id = v_cust;
  perform post_journal(v_org, v_date, format('Receipt %s — %s', v_no, v_cust_name), 'receipts', v_id,
    v_lines || jsonb_build_object('account', 'DEBTORS', 'credit', round(v_total, 2)));
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 7. Payments: supplier, staff wages, or an expense head.
-- ------------------------------------------------------------
create or replace view v_payment_list as
select p.id, p.org_id, p.payment_no, p.payment_date, p.amount, p.reference, p.narration, p.created_by, p.created_at,
       p.mode_id, m.code as mode_code,
       p.supplier_id, s.name as supplier_name,
       p.staff_id, st.full_name as staff_name,
       p.expense_head_id, e.name as expense_head,
       case when p.supplier_id is not null then 'supplier'
            when p.staff_id is not null then 'staff'
            else 'expense' end as party_kind,
       coalesce(s.name, st.full_name, e.name) as party_name
from payments p
left join receipt_modes m on m.id = p.mode_id
left join suppliers s on s.id = p.supplier_id
left join staff st on st.id = p.staff_id
left join expense_heads e on e.id = p.expense_head_id;
alter view v_payment_list set (security_invoker = on);

create or replace function save_payment(p jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; v_amt numeric; v_date date; m receipt_modes%rowtype;
  v_sup uuid := nullif(p->>'supplier_id','')::uuid; v_staff uuid := nullif(p->>'staff_id','')::uuid; v_head uuid := nullif(p->>'expense_head_id','')::uuid;
  v_party text; v_no text; v_acct text;
begin
  if (v_sup is not null)::int + (v_staff is not null)::int + (v_head is not null)::int <> 1 then
    raise exception 'A payment goes to exactly one of: supplier, staff member, expense head';
  end if;
  v_amt := coalesce((p->>'amount')::numeric, 0);
  if v_amt <= 0 then raise exception 'Amount must be greater than zero'; end if;
  v_date := coalesce(nullif(p->>'payment_date','')::date, current_date);
  select * into m from receipt_modes where id = nullif(p->>'mode_id','')::uuid and org_id = v_org;
  if not found then raise exception 'Choose how it was paid (mode)'; end if;
  if not m.is_collection then raise exception '% is a deduction head, not a way to pay', m.code; end if;
  if m.needs_reference and nullif(trim(coalesce(p->>'reference','')), '') is null then
    raise exception '% needs a reference number', m.code;
  end if;

  v_no := next_doc_no(v_org, 'payment');
  insert into payments (org_id, payment_no, supplier_id, staff_id, expense_head_id, payment_date, mode_id, amount, reference, narration, created_by)
  values (v_org, v_no, v_sup, v_staff, v_head, v_date, m.id, round(v_amt, 2),
          nullif(trim(coalesce(p->>'reference','')), ''), nullif(p->>'narration',''), my_staff_id())
  returning id into v_id;

  select coalesce(s.name, st.full_name, e.name), case when v_sup is not null then 'CREDITORS' when v_staff is not null then 'WAGES' else 'EXPENSES' end
    into v_party, v_acct
  from (select 1) x
  left join suppliers s on s.id = v_sup
  left join staff st on st.id = v_staff
  left join expense_heads e on e.id = v_head;

  perform post_journal(v_org, v_date, format('Payment %s — %s', v_no, v_party), 'payments', v_id,
    jsonb_build_array(
      jsonb_build_object('account', v_acct, 'debit', round(v_amt, 2)),
      jsonb_build_object('account', case when upper(m.code) = 'CASH' then 'CASH' else 'BANK' end, 'credit', round(v_amt, 2))));
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 8. Suppliers list (simple master used by purchases & payments)
-- ------------------------------------------------------------
create or replace view v_supplier_list as
select s.*, coalesce((select sum(total - paid_amount) from purchases p where p.supplier_id = s.id), 0)
             - coalesce((select sum(amount) from payments pm where pm.supplier_id = s.id), 0)
             + s.opening_balance as payable
from suppliers s;
alter view v_supplier_list set (security_invoker = on);

-- Trial balance helper: must be zero for any org at any time.
create or replace function trial_balance_check(p_org uuid, p_from date default null, p_to date default null)
returns numeric language sql stable as $$
  select coalesce(sum(jl.debit) - sum(jl.credit), 0)
  from journal_lines jl join journal_entries je on je.id = jl.entry_id
  where je.org_id = p_org
    and (p_from is null or je.entry_date >= p_from)
    and (p_to   is null or je.entry_date <= p_to);
$$;
