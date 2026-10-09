-- ============================================================
-- JYOTHI FOODS ERP — 58: RECEIPT OPENING BALANCE, PURCHASE PRINT & STOCK REPORT
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- 1. Receipt: when a customer pays credit amount, clear their opening
--    balance FIRST before allocating to invoices.
-- 2. Purchase print: include supplier's phone and town/address.
-- 3. Purchase edit: unposting reverses on the bill's original date so
--    stock reports do not treat an edit as an extra new purchase.
-- ============================================================

-- ------------------------------------------------------------
-- 1. RECEIPT ALLOCATIONS TO OPENING BALANCE
-- ------------------------------------------------------------
alter table receipt_allocations alter column invoice_id drop not null;

create or replace view v_receipt_allocations as
select a.id, a.receipt_id, a.invoice_id,
       case when a.invoice_id is null then 'OPENING BALANCE' else i.invoice_no end as invoice_no,
       case when a.invoice_id is null then null else i.invoice_date end as invoice_date,
       a.amount
from receipt_allocations a
left join invoices i on i.id = a.invoice_id;
alter view v_receipt_allocations set (security_invoker = on);

create or replace view v_customer_list as
select c.id, c.org_id, c.code, c.name, c.mobile1, c.mobile2, c.mobile3, c.town, c.address,
       c.route_id, r.name as route_name, c.price_group, c.credit_limit, c.opening_balance,
       c.whatsapp_opt_in, c.is_active, c.created_at, c.price_list_id,
       coalesce(o.outstanding, 0) as outstanding,
       greatest(0, c.opening_balance - coalesce((
         select sum(ra.amount) from receipt_allocations ra join receipts rc on rc.id = ra.receipt_id
          where rc.customer_id = c.id and ra.invoice_id is null
       ), 0)) as opening_balance_remaining
from customers c
left join routes r on r.id = c.route_id
left join v_customer_outstanding o on o.customer_id = c.id;
alter view v_customer_list set (security_invoker = on);

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
           greatest(0, c.opening_balance - coalesce((
             select sum(ra.amount) from receipt_allocations ra join receipts rc on rc.id = ra.receipt_id
              where rc.customer_id = c.id and ra.invoice_id is null and rc.receipt_date <= p_as_on
           ), 0)) as rem
      from customers c where c.org_id = p_org)
  select c.id, c.name, c.town, rt.name, c.mobile1,
         coalesce(orem.rem, c.opening_balance),
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
  select greatest(0, c.opening_balance - coalesce((
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

-- ------------------------------------------------------------
-- 2. PURCHASE DETAILS ON PURCHASE LIST VIEW
-- ------------------------------------------------------------
alter table suppliers add column if not exists address text;

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

-- ------------------------------------------------------------
-- 3. UNPOSTING ON PURCHASE CORRECTION REVERSES ON THE BILL'S DATE
-- ------------------------------------------------------------
create or replace function unpost_purchase_stock(p_purchase uuid, p_on date default null)
returns int language plpgsql as $$
declare v_net numeric; n int := 0;
begin
  select coalesce(sum(qty_base), 0) into v_net
    from stock_ledger where ref_table = 'purchases' and ref_id = p_purchase;
  if v_net = 0 then return 0; end if;   -- never posted, or already taken back

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select org_id, item_id, location_id, 'purchase', coalesce(p_on, max(txn_date)),
         -sum(qty_base), max(rate), 'purchases', ref_id, max(created_by)
    from stock_ledger
   where ref_table = 'purchases' and ref_id = p_purchase
   group by org_id, item_id, location_id, ref_id
  having sum(qty_base) <> 0;
  get diagnostics n = row_count;
  return n;
end $$;

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
