-- ============================================================
-- JYOTHI FOODS ERP — 15: DOCUMENTS & PRICING (T8)
-- Quotation (the client's real starting form), sale & purchase
-- orders with partial fulfilment, delivery challans, purchase
-- returns (debit notes), named price lists and discount schemes.
-- Every conversion re-uses the lines — nothing is re-typed.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Module-gated RLS for the document tables.
-- ------------------------------------------------------------
create table if not exists order_fulfilments (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  order_id   uuid not null references orders(id) on delete cascade,
  ref_table  text not null,                 -- 'invoices' | 'purchases'
  ref_id     uuid not null,
  boxes      numeric(16,3) not null default 0,
  created_at timestamptz not null default now()
);
alter table order_fulfilments enable row level security;

do $$
declare r record;
begin
  for r in select * from (values
      ('quotations',        'invoices',  false),
      ('orders',            'invoices',  false),
      ('order_fulfilments', 'invoices',  false),
      ('delivery_challans', 'invoices',  false),
      ('purchase_returns',  'purchases', true),
      ('price_lists',       'items',     false),
      ('discount_schemes',  'items',     false)
    ) as t(tbl, module, gate_read)
  loop
    execute format('drop policy if exists org_read on %I', r.tbl);
    execute format('drop policy if exists org_write on %I', r.tbl);
    execute format('drop policy if exists mod_insert on %I', r.tbl);
    execute format('drop policy if exists mod_update on %I', r.tbl);
    execute format('drop policy if exists mod_delete on %I', r.tbl);
    if r.gate_read then
      execute format('create policy org_read on %I for select using (org_id = my_org_id() and can_view(%L))', r.tbl, r.module);
    else
      execute format('create policy org_read on %I for select using (org_id = my_org_id())', r.tbl);
    end if;
    execute format('create policy mod_insert on %I for insert with check (org_id = my_org_id() and can_edit(%L))', r.tbl, r.module);
    execute format('create policy mod_update on %I for update using (org_id = my_org_id() and can_edit(%L)) with check (org_id = my_org_id() and can_edit(%L))', r.tbl, r.module, r.module);
    execute format('create policy mod_delete on %I for delete using (org_id = my_org_id() and can_delete(%L))', r.tbl, r.module);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 2. Price lists: named, dated, per customer, one default.
--    Rate resolution: customer override → price-group override →
--    the customer's list → the default list → the item master.
-- ------------------------------------------------------------
alter table price_lists add column if not exists notes text, add column if not exists updated_at timestamptz not null default now();
alter table price_list_items add column if not exists updated_at timestamptz not null default now();

create or replace function t_one_default_price_list() returns trigger language plpgsql as $$
begin
  if new.is_default then
    update price_lists set is_default = false where org_id = new.org_id and id <> new.id and is_default;
  end if;
  return new;
end $$;
drop trigger if exists t_one_default_price_list on price_lists;
create trigger t_one_default_price_list after insert or update of is_default on price_lists for each row execute function t_one_default_price_list();

create or replace function price_list_rate(p_list uuid, p_item uuid, p_date date) returns numeric
language sql stable as $$
  select pli.unit_rate from price_lists pl join price_list_items pli on pli.price_list_id = pl.id
   where pl.id = p_list and pli.item_id = p_item and pl.is_active
     and p_date >= coalesce(pl.valid_from, p_date) and p_date <= coalesce(pl.valid_to, p_date);
$$;

create or replace function effective_unit_rate(p_item uuid, p_customer uuid, p_date date default current_date)
returns numeric language sql stable as $$
  select coalesce(
    (select o.unit_rate from item_price_overrides o
      where o.item_id = p_item and o.customer_id = p_customer
        and p_date between o.valid_from and coalesce(o.valid_to, p_date)
      order by o.valid_from desc limit 1),
    (select o.unit_rate from item_price_overrides o
       join customers c on c.price_group = o.price_group
      where o.item_id = p_item and c.id = p_customer and o.customer_id is null
        and p_date between o.valid_from and coalesce(o.valid_to, p_date)
      order by o.valid_from desc limit 1),
    (select price_list_rate(c.price_list_id, p_item, p_date) from customers c where c.id = p_customer),
    (select price_list_rate(pl.id, p_item, p_date) from price_lists pl
      where pl.org_id = (select org_id from items where id = p_item) and pl.is_default and pl.is_active limit 1),
    (select i.unit_rate from items i where i.id = p_item)
  );
$$;

create or replace view v_price_lists as
select pl.*,
       (select count(*) from price_list_items pli where pli.price_list_id = pl.id) as item_count,
       (select count(*) from customers c where c.price_list_id = pl.id and c.is_active) as customer_count,
       (pl.valid_to is not null and pl.valid_to < current_date) as is_expired
  from price_lists pl;
alter view v_price_lists set (security_invoker = on);

/** Every finished item with its master rate and the list's rate (null = falls through). */
create or replace function price_list_rates(p_list uuid)
returns table (item_id uuid, item_code text, item_name text, section_name text, units_per_box integer, master_rate numeric, list_rate numeric, list_box_rate numeric)
language sql stable as $$
  select i.id, i.item_code, i.name, s.name, i.units_per_box, i.unit_rate, pli.unit_rate, round(pli.unit_rate * i.units_per_box, 2)
    from items i
    join price_lists pl on pl.id = p_list and pl.org_id = i.org_id
    left join sections s on s.id = i.section_id
    left join price_list_items pli on pli.price_list_id = p_list and pli.item_id = i.id
   where i.is_active and i.type = 'finished_good'
   order by s.sort_order nulls last, i.item_code;
$$;

/** One rate; null removes the item from the list so it falls through to the default / master. */
create or replace function set_price_list_rate(p_list uuid, p_item uuid, p_rate numeric) returns void
language plpgsql as $$
begin
  if not exists (select 1 from price_lists where id = p_list and org_id = my_org_id()) then raise exception 'Price list not found'; end if;
  if p_rate is null then
    delete from price_list_items where price_list_id = p_list and item_id = p_item;
  else
    if p_rate < 0 then raise exception 'Rate cannot be negative'; end if;
    insert into price_list_items (price_list_id, item_id, unit_rate) values (p_list, p_item, round(p_rate, 2))
    on conflict (price_list_id, item_id) do update set unit_rate = excluded.unit_rate, updated_at = now();
  end if;
  update price_lists set updated_at = now() where id = p_list;
end $$;

/**
 * Bulk rate update. mode: 'pct' (± % on existing rates), 'add' (± ₹ on existing rates),
 * 'copy_master' (fill every finished item from the master, optionally ± %), 'copy_list'
 * (copy another list, optionally ± %). p_section limits to one mestri section.
 */
create or replace function bulk_update_price_list(p_list uuid, p_mode text, p_value numeric default 0, p_section uuid default null, p_source_list uuid default null)
returns integer language plpgsql as $$
declare n int;
begin
  if not exists (select 1 from price_lists where id = p_list and org_id = my_org_id()) then raise exception 'Price list not found'; end if;
  if p_mode = 'pct' then
    update price_list_items pli set unit_rate = round(pli.unit_rate * (1 + coalesce(p_value, 0) / 100), 2), updated_at = now()
      from items i where i.id = pli.item_id and pli.price_list_id = p_list and (p_section is null or i.section_id = p_section);
  elsif p_mode = 'add' then
    update price_list_items pli set unit_rate = greatest(round(pli.unit_rate + coalesce(p_value, 0), 2), 0), updated_at = now()
      from items i where i.id = pli.item_id and pli.price_list_id = p_list and (p_section is null or i.section_id = p_section);
  elsif p_mode = 'copy_master' then
    insert into price_list_items (price_list_id, item_id, unit_rate)
    select p_list, i.id, round(i.unit_rate * (1 + coalesce(p_value, 0) / 100), 2) from items i
     where i.org_id = my_org_id() and i.is_active and i.type = 'finished_good' and i.unit_rate is not null and (p_section is null or i.section_id = p_section)
    on conflict (price_list_id, item_id) do update set unit_rate = excluded.unit_rate, updated_at = now();
  elsif p_mode = 'copy_list' then
    if p_source_list is null or p_source_list = p_list then raise exception 'Pick the list to copy from'; end if;
    insert into price_list_items (price_list_id, item_id, unit_rate)
    select p_list, s.item_id, round(s.unit_rate * (1 + coalesce(p_value, 0) / 100), 2) from price_list_items s join items i on i.id = s.item_id
     where s.price_list_id = p_source_list and (p_section is null or i.section_id = p_section)
    on conflict (price_list_id, item_id) do update set unit_rate = excluded.unit_rate, updated_at = now();
  else
    raise exception 'Unknown mode %', p_mode;
  end if;
  get diagnostics n = row_count;
  update price_lists set updated_at = now() where id = p_list;
  return n;
end $$;

/** Put every customer on a route / in a town (or everyone) on a list. */
create or replace function assign_price_list(p_list uuid, p_route uuid default null, p_town text default null) returns integer
language plpgsql as $$
declare n int;
begin
  if p_list is not null and not exists (select 1 from price_lists where id = p_list and org_id = my_org_id()) then raise exception 'Price list not found'; end if;
  update customers set price_list_id = p_list
   where org_id = my_org_id() and is_active
     and (p_route is null or route_id = p_route) and (p_town is null or town ilike p_town);
  get diagnostics n = row_count;
  return n;
end $$;

-- ------------------------------------------------------------
-- 3. Discount schemes: min boxes → discount % or free boxes.
-- ------------------------------------------------------------
create or replace view v_discount_schemes as
select d.*, i.item_code, i.name as item_name, s.name as section_name,
       (d.valid_to is not null and d.valid_to < current_date) as is_expired
  from discount_schemes d left join items i on i.id = d.item_id left join sections s on s.id = d.section_id;
alter view v_discount_schemes set (security_invoker = on);

/** The best scheme for this item at this quantity: item-specific beats section beats all-items. */
create or replace function discount_for(p_org uuid, p_item uuid, p_boxes numeric, p_date date default current_date)
returns table (scheme_id uuid, name text, min_boxes numeric, discount_pct numeric, free_boxes numeric)
language sql stable as $$
  select d.id, d.name, d.min_boxes, coalesce(d.discount_pct, 0), coalesce(d.free_boxes, 0)
    from discount_schemes d join items i on i.id = p_item
   where d.org_id = p_org and d.is_active
     and p_date >= coalesce(d.valid_from, p_date) and p_date <= coalesce(d.valid_to, p_date)
     and (d.item_id = p_item or (d.item_id is null and d.section_id = i.section_id) or (d.item_id is null and d.section_id is null))
     and p_boxes >= coalesce(d.min_boxes, 0)
   order by (d.item_id is not null) desc, (d.section_id is not null) desc, coalesce(d.discount_pct, 0) desc, coalesce(d.free_boxes, 0) desc
   limit 1;
$$;

/**
 * Apply the schemes to a draft invoice: sets the discount amount and adds free-box lines
 * at rate 0 (removing the ones a previous run added). Returns what it did.
 */
create or replace function apply_discount_schemes(p_invoice uuid) returns jsonb
language plpgsql as $$
declare inv invoices%rowtype; l record; d record; v_disc numeric := 0; v_free jsonb := '[]'::jsonb; v_n numeric;
begin
  select * into inv from invoices where id = p_invoice;
  if not found then raise exception 'Invoice not found'; end if;
  if inv.status <> 'draft' then raise exception 'Schemes apply to a draft; this invoice is %', inv.status; end if;
  delete from invoice_items where invoice_id = p_invoice and rate = 0 and amount = 0;
  for l in select ii.item_id, sum(ii.boxes) as boxes, sum(ii.amount) as amount from invoice_items ii where ii.invoice_id = p_invoice and ii.rate > 0 group by ii.item_id loop
    select * into d from discount_for(inv.org_id, l.item_id, l.boxes, inv.invoice_date);
    if not found then continue; end if;
    if d.discount_pct > 0 then v_disc := v_disc + round(l.amount * d.discount_pct / 100, 2); end if;
    if d.free_boxes > 0 and coalesce(d.min_boxes, 0) > 0 then
      v_n := floor(l.boxes / d.min_boxes) * d.free_boxes;
      if v_n > 0 then
        insert into invoice_items (invoice_id, item_id, boxes, rate) values (p_invoice, l.item_id, v_n, 0);
        v_free := v_free || jsonb_build_object('item_id', l.item_id, 'boxes', v_n, 'scheme', d.name);
      end if;
    end if;
  end loop;
  update invoices set discount = round(v_disc, 2) where id = p_invoice;
  return jsonb_build_object('discount', round(v_disc, 2), 'free_lines', v_free);
end $$;

alter table orders add column if not exists created_at timestamptz not null default now();
alter table delivery_challans add column if not exists created_at timestamptz not null default now();
alter table purchase_returns add column if not exists created_at timestamptz not null default now();

-- ------------------------------------------------------------
-- 4. Shared line arithmetic for quotation / order / challan lines.
-- ------------------------------------------------------------
create or replace function doc_line(p_item uuid, p_boxes numeric, p_rate numeric)
returns table (units_per_box numeric, uom_id uuid, qty numeric, qty_base numeric, amount numeric)
language sql stable as $$
  select i.units_per_box::numeric, i.base_uom_id, p_boxes * i.units_per_box,
         to_base_qty(i.id, p_boxes * i.units_per_box, i.base_uom_id), round(p_boxes * i.units_per_box * coalesce(p_rate, 0), 2)
    from items i where i.id = p_item;
$$;

-- ------------------------------------------------------------
-- 5. Quotations — same grid as the invoice, a validity date, and
--    "convert" that hands the lines to save_invoice untouched.
-- ------------------------------------------------------------
create or replace view v_quotation_list as
select q.id, q.org_id, q.quote_no, q.quote_date, q.valid_till, q.state, q.customer_id, c.name as customer_name, c.town as customer_town, c.mobile1 as customer_mobile,
       q.transport_name, q.lr_no, q.lr_date, q.freight, q.discount, q.round_off, q.subtotal, q.total, q.notes, q.invoice_id, i.invoice_no, q.created_by, q.created_at,
       (select coalesce(sum(boxes), 0) from quotation_items x where x.quotation_id = q.id) as total_boxes,
       (select coalesce(sum(qty), 0) from quotation_items x where x.quotation_id = q.id) as total_qty,
       (select count(*) from quotation_items x where x.quotation_id = q.id) as line_count,
       (q.state = 'open' and q.valid_till is not null and q.valid_till < current_date) as is_expired
  from quotations q join customers c on c.id = q.customer_id left join invoices i on i.id = q.invoice_id;
alter view v_quotation_list set (security_invoker = on);

create or replace view v_quotation_lines as
select qi.id, qi.quotation_id, qi.item_id, i.item_code, i.name as item_name, pt.code as pack_code, qi.units_per_box, qi.boxes, qi.qty, qi.rate, qi.amount, qi.uom_id, qi.qty_base
  from quotation_items qi join items i on i.id = qi.item_id left join pack_types pt on pt.id = i.pack_type_id;
alter view v_quotation_lines set (security_invoker = on);

create or replace function save_quotation(p_header jsonb, p_lines jsonb) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p_header->>'id', '')::uuid; v_state doc_state; l jsonb; n int := 0; v_cust uuid; v_date date; v_rate numeric; d record; v_sub numeric := 0;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'A quotation needs at least one line'; end if;
  v_cust := (p_header->>'customer_id')::uuid;
  v_date := coalesce(nullif(p_header->>'quote_date', '')::date, current_date);
  if v_id is null then
    insert into quotations (org_id, quote_no, customer_id, quote_date, valid_till, transport_name, lr_no, lr_date, freight, discount, round_off, notes, created_by)
    values (v_org, next_doc_no(v_org, 'quotation'), v_cust, v_date, nullif(p_header->>'valid_till', '')::date,
            nullif(p_header->>'transport_name', ''), nullif(p_header->>'lr_no', ''), nullif(p_header->>'lr_date', '')::date,
            coalesce(nullif(p_header->>'freight', '')::numeric, 0), coalesce(nullif(p_header->>'discount', '')::numeric, 0),
            coalesce(nullif(p_header->>'round_off', '')::numeric, 0), nullif(p_header->>'notes', ''), my_staff_id())
    returning id into v_id;
  else
    select state into v_state from quotations where id = v_id and org_id = v_org;
    if v_state is null then raise exception 'Quotation not found'; end if;
    if v_state <> 'open' then raise exception 'Quotation is %; only open quotations can be edited', v_state; end if;
    update quotations set customer_id = v_cust, quote_date = v_date, valid_till = nullif(p_header->>'valid_till', '')::date,
           transport_name = nullif(p_header->>'transport_name', ''), lr_no = nullif(p_header->>'lr_no', ''), lr_date = nullif(p_header->>'lr_date', '')::date,
           freight = coalesce(nullif(p_header->>'freight', '')::numeric, 0), discount = coalesce(nullif(p_header->>'discount', '')::numeric, 0),
           round_off = coalesce(nullif(p_header->>'round_off', '')::numeric, 0), notes = nullif(p_header->>'notes', '')
     where id = v_id;
    delete from quotation_items where quotation_id = v_id;
  end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    if coalesce((l->>'boxes')::numeric, 0) <= 0 then raise exception 'Line %: boxes must be greater than zero', n; end if;
    v_rate := coalesce(nullif(l->>'rate', '')::numeric, effective_unit_rate((l->>'item_id')::uuid, v_cust, v_date));
    select * into d from doc_line((l->>'item_id')::uuid, (l->>'boxes')::numeric, v_rate);
    if d.units_per_box is null then raise exception 'Line %: item not found', n; end if;
    insert into quotation_items (quotation_id, item_id, units_per_box, boxes, qty, uom_id, qty_base, rate, amount)
    values (v_id, (l->>'item_id')::uuid, d.units_per_box, (l->>'boxes')::numeric, d.qty, d.uom_id, d.qty_base, v_rate, d.amount);
    v_sub := v_sub + d.amount;
  end loop;
  update quotations set subtotal = round(v_sub, 2), total = round(v_sub - discount + coalesce(freight, 0) + round_off, 2) where id = v_id;
  return v_id;
end $$;

create or replace function set_quotation_state(p_quote uuid, p_state doc_state) returns void
language plpgsql as $$
declare q quotations%rowtype;
begin
  select * into q from quotations where id = p_quote;
  if not found then raise exception 'Quotation not found'; end if;
  if q.state = 'converted' then raise exception 'Quotation % is already an invoice', q.quote_no; end if;
  if p_state not in ('open', 'cancelled') then raise exception 'A quotation can only be open or cancelled by hand'; end if;
  update quotations set state = p_state where id = p_quote;
end $$;

/** One click: the invoice gets the customer, transport block and every line as quoted. */
create or replace function convert_quotation(p_quote uuid, p_location uuid, p_invoice_date date default current_date) returns uuid
language plpgsql as $$
declare q quotations%rowtype; v_inv uuid; v_lines jsonb;
begin
  select * into q from quotations where id = p_quote;
  if not found then raise exception 'Quotation not found'; end if;
  if q.state <> 'open' then raise exception 'Quotation % is %', q.quote_no, q.state; end if;
  select jsonb_agg(jsonb_build_object('item_id', item_id, 'boxes', boxes, 'rate', rate)) into v_lines from quotation_items where quotation_id = p_quote;
  v_inv := save_invoice(jsonb_build_object('customer_id', q.customer_id, 'invoice_date', p_invoice_date, 'location_id', p_location,
                          'transport_name', q.transport_name, 'lr_no', q.lr_no, 'lr_date', q.lr_date, 'freight', q.freight,
                          'discount', q.discount, 'round_off', q.round_off, 'notes', coalesce(q.notes, '') || format(' (from quotation %s)', q.quote_no)), v_lines);
  update quotations set state = 'converted', invoice_id = v_inv where id = p_quote;
  return v_inv;
end $$;

-- ------------------------------------------------------------
-- 6. Sale & purchase orders with partial fulfilment.
-- ------------------------------------------------------------
create or replace view v_order_list as
select o.id, o.org_id, o.kind, o.order_no, o.order_date, o.due_date, o.state, o.customer_id, o.supplier_id,
       coalesce(c.name, s.name) as party_name, c.town as party_town, o.total, o.advance, o.notes, o.source_inbound_id, o.created_by, o.created_at,
       (select count(*) from order_items x where x.order_id = o.id) as line_count,
       (select coalesce(sum(boxes), 0) from order_items x where x.order_id = o.id) as total_boxes,
       (select coalesce(sum(round(delivered_base / nullif(units_per_box, 0), 3)), 0) from order_items x where x.order_id = o.id) as delivered_boxes,
       (select count(*) from order_fulfilments f where f.order_id = o.id) as fulfilments,
       (o.state in ('open', 'partial') and o.due_date is not null and o.due_date < current_date) as is_overdue
  from orders o left join customers c on c.id = o.customer_id left join suppliers s on s.id = o.supplier_id;
alter view v_order_list set (security_invoker = on);

create or replace view v_order_lines as
select oi.id, oi.order_id, oi.item_id, i.item_code, i.name as item_name, oi.units_per_box, oi.boxes, oi.qty, oi.rate, oi.amount, oi.uom_id, oi.qty_base, oi.delivered_base,
       round(oi.delivered_base / nullif(oi.units_per_box, 0), 3) as delivered_boxes,
       round(oi.boxes - oi.delivered_base / nullif(oi.units_per_box, 0), 3) as pending_boxes
  from order_items oi join items i on i.id = oi.item_id;
alter view v_order_lines set (security_invoker = on);

create or replace view v_order_fulfilments as
select f.*, case f.ref_table when 'invoices' then (select invoice_no from invoices where id = f.ref_id) when 'purchases' then (select bill_no from purchases where id = f.ref_id) end as doc_no,
       case f.ref_table when 'invoices' then (select invoice_date from invoices where id = f.ref_id) when 'purchases' then (select bill_date from purchases where id = f.ref_id) end as doc_date
  from order_fulfilments f;
alter view v_order_fulfilments set (security_invoker = on);


create or replace function save_order(p_header jsonb, p_lines jsonb) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p_header->>'id', '')::uuid; o orders%rowtype; l jsonb; n int := 0; v_kind order_kind; v_cust uuid; v_sup uuid; v_date date; v_rate numeric; d record; v_total numeric := 0;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'An order needs at least one line'; end if;
  v_kind := coalesce(nullif(p_header->>'kind', ''), 'sale')::order_kind;
  v_cust := nullif(p_header->>'customer_id', '')::uuid; v_sup := nullif(p_header->>'supplier_id', '')::uuid;
  if v_kind = 'sale' and v_cust is null then raise exception 'A sale order needs a customer'; end if;
  if v_kind = 'purchase' and v_sup is null then raise exception 'A purchase order needs a supplier'; end if;
  v_date := coalesce(nullif(p_header->>'order_date', '')::date, current_date);
  if v_id is null then
    insert into orders (org_id, kind, order_no, customer_id, supplier_id, order_date, due_date, advance, source_inbound_id, notes, created_by)
    values (v_org, v_kind, next_doc_no(v_org, case v_kind when 'sale' then 'sale_order' else 'purchase_order' end), v_cust, v_sup, v_date,
            nullif(p_header->>'due_date', '')::date, coalesce(nullif(p_header->>'advance', '')::numeric, 0), nullif(p_header->>'source_inbound_id', '')::uuid,
            nullif(p_header->>'notes', ''), my_staff_id())
    returning id into v_id;
  else
    select * into o from orders where id = v_id and org_id = v_org;
    if not found then raise exception 'Order not found'; end if;
    if o.state <> 'open' then raise exception 'Order % is %; only open orders can be edited', o.order_no, o.state; end if;
    if exists (select 1 from order_items where order_id = v_id and delivered_base > 0) then raise exception 'Order % has deliveries; edit is closed', o.order_no; end if;
    update orders set customer_id = v_cust, supplier_id = v_sup, order_date = v_date, due_date = nullif(p_header->>'due_date', '')::date,
           advance = coalesce(nullif(p_header->>'advance', '')::numeric, 0), notes = nullif(p_header->>'notes', '') where id = v_id;
    delete from order_items where order_id = v_id;
  end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    if coalesce((l->>'boxes')::numeric, 0) <= 0 then raise exception 'Line %: boxes must be greater than zero', n; end if;
    v_rate := coalesce(nullif(l->>'rate', '')::numeric,
                       case when v_kind = 'sale' then effective_unit_rate((l->>'item_id')::uuid, v_cust, v_date) else (select purchase_rate from items where id = (l->>'item_id')::uuid) end, 0);
    select * into d from doc_line((l->>'item_id')::uuid, (l->>'boxes')::numeric, v_rate);
    if d.units_per_box is null then raise exception 'Line %: item not found', n; end if;
    insert into order_items (order_id, item_id, units_per_box, boxes, qty, uom_id, qty_base, rate, amount)
    values (v_id, (l->>'item_id')::uuid, d.units_per_box, (l->>'boxes')::numeric, d.qty, d.uom_id, d.qty_base, v_rate, d.amount);
    v_total := v_total + d.amount;
  end loop;
  update orders set total = round(v_total, 2) where id = v_id;
  return v_id;
end $$;

create or replace function cancel_order(p_order uuid) returns void
language plpgsql as $$
declare o orders%rowtype;
begin
  select * into o from orders where id = p_order;
  if not found then raise exception 'Order not found'; end if;
  if o.state in ('completed', 'cancelled') then raise exception 'Order % is already %', o.order_no, o.state; end if;
  update orders set state = 'cancelled' where id = p_order;
end $$;

/**
 * Deliver (sale → draft invoice) or receive (purchase → purchase bill) some or all of
 * the pending boxes. p_lines [{item_id, boxes}] or null for everything still pending.
 * p_extra: {location_id, doc_date, bill_no, paid_amount, other_charges, transport_name, lr_no, lr_date, freight}
 */
create or replace function fulfil_order(p_order uuid, p_lines jsonb default null, p_extra jsonb default '{}'::jsonb) returns uuid
language plpgsql as $$
declare o orders%rowtype; l record; v_boxes numeric; v_doc uuid; v_lines jsonb := '[]'::jsonb; v_pending numeric; v_date date; v_loc uuid; v_total_boxes numeric := 0; v_remaining numeric;
begin
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Order not found'; end if;
  if o.state not in ('open', 'partial') then raise exception 'Order % is %', o.order_no, o.state; end if;
  v_date := coalesce(nullif(p_extra->>'doc_date', '')::date, current_date);
  v_loc := nullif(p_extra->>'location_id', '')::uuid;
  if v_loc is null then raise exception 'Pick the stock location'; end if;

  for l in select oi.*, v.pending_boxes from order_items oi join v_order_lines v on v.id = oi.id where oi.order_id = p_order order by oi.id loop
    if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
      v_boxes := l.pending_boxes;
    else
      select coalesce(sum((x->>'boxes')::numeric), 0) into v_boxes from jsonb_array_elements(p_lines) x where (x->>'item_id')::uuid = l.item_id;
    end if;
    if v_boxes <= 0 then continue; end if;
    if v_boxes > l.pending_boxes + 0.0005 then
      raise exception '% : % boxes asked, only % pending on order %', (select item_code from items where id = l.item_id), v_boxes, l.pending_boxes, o.order_no;
    end if;
    if o.kind = 'sale' then
      v_lines := v_lines || jsonb_build_object('item_id', l.item_id, 'boxes', v_boxes, 'rate', l.rate);
    else
      v_lines := v_lines || jsonb_build_object('item_id', l.item_id, 'qty', v_boxes * l.units_per_box, 'uom_id', l.uom_id, 'rate', l.rate);
    end if;
    update order_items set delivered_base = delivered_base + v_boxes * l.units_per_box where id = l.id;
    v_total_boxes := v_total_boxes + v_boxes;
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'Nothing to deliver — every line is already fulfilled'; end if;

  if o.kind = 'sale' then
    v_doc := save_invoice(jsonb_build_object('customer_id', o.customer_id, 'invoice_date', v_date, 'location_id', v_loc,
               'transport_name', p_extra->>'transport_name', 'lr_no', p_extra->>'lr_no', 'lr_date', p_extra->>'lr_date', 'freight', coalesce(p_extra->>'freight', '0'),
               'notes', format('Against order %s', o.order_no)), v_lines);
    insert into order_fulfilments (org_id, order_id, ref_table, ref_id, boxes) values (o.org_id, p_order, 'invoices', v_doc, v_total_boxes);
  else
    v_doc := save_purchase(jsonb_build_object('supplier_id', o.supplier_id, 'bill_no', p_extra->>'bill_no', 'bill_date', v_date, 'location_id', v_loc,
               'other_charges', coalesce(p_extra->>'other_charges', '0'), 'paid_amount', coalesce(p_extra->>'paid_amount', '0'),
               'notes', format('Against order %s', o.order_no)), v_lines);
    insert into order_fulfilments (org_id, order_id, ref_table, ref_id, boxes) values (o.org_id, p_order, 'purchases', v_doc, v_total_boxes);
  end if;

  select coalesce(sum(pending_boxes), 0) into v_remaining from v_order_lines where order_id = p_order;
  update orders set state = (case when v_remaining <= 0.0005 then 'completed' else 'partial' end)::doc_state where id = p_order;
  return v_doc;
end $$;

/** WhatsApp / call order → sale order (still nothing invoiced). */
create or replace function convert_inbound_to_order(p_inbound uuid, p_header jsonb, p_lines jsonb) returns uuid
language plpgsql as $$
declare io inbound_orders%rowtype; v_id uuid;
begin
  select * into io from inbound_orders where id = p_inbound for update;
  if not found then raise exception 'Order not found'; end if;
  if io.status not in ('new', 'confirmed') then raise exception 'Order is already %', io.status; end if;
  v_id := save_order(p_header || jsonb_build_object('kind', 'sale', 'source_inbound_id', p_inbound), p_lines);
  update inbound_orders set status = 'confirmed', customer_id = (p_header->>'customer_id')::uuid, handled_by = my_staff_id(), handled_at = now() where id = p_inbound;
  return v_id;
end $$;

drop view if exists v_inbound_orders;
create view v_inbound_orders as
select o.id, o.org_id, o.customer_id, c.name as customer_name, c.town as customer_town, coalesce(c.mobile1, o.from_number) as mobile1,
       o.from_number, o.raw_text, o.transcript, o.audio_url, o.parsed_items,
       jsonb_array_length(coalesce(o.parsed_items, '[]'::jsonb)) as line_count,
       o.confidence, o.source, o.status, o.invoice_id, i.invoice_no, o.notes, o.reject_reason,
       o.handled_by, st.full_name as handled_by_name, o.handled_at, o.created_at,
       so.id as order_id, so.order_no
  from inbound_orders o
  left join customers c on c.id = o.customer_id
  left join invoices i on i.id = o.invoice_id
  left join staff st on st.id = o.handled_by
  left join lateral (select id, order_no from orders x where x.source_inbound_id = o.id order by x.created_at desc limit 1) so on true;
alter view v_inbound_orders set (security_invoker = on);

-- ------------------------------------------------------------
-- 7. Delivery challans: goods out before billing. Stock leaves on
--    save (a 'sale' row referencing the challan); converting bills
--    it — the challan rows reverse and the confirmed invoice posts.
-- ------------------------------------------------------------
create or replace view v_challan_list as
select d.id, d.org_id, d.challan_no, d.challan_date, d.state, d.customer_id, c.name as customer_name, c.town as customer_town,
       d.location_id, l.name as location_name, d.vehicle_id, v.vehicle_number, d.trip_id, d.invoice_id, i.invoice_no, d.notes, d.created_by, d.created_at,
       (select count(*) from challan_items x where x.challan_id = d.id) as line_count,
       (select coalesce(sum(boxes), 0) from challan_items x where x.challan_id = d.id) as total_boxes,
       (select coalesce(sum(qty), 0) from challan_items x where x.challan_id = d.id) as total_qty
  from delivery_challans d join customers c on c.id = d.customer_id
  left join stock_locations l on l.id = d.location_id left join vehicles v on v.id = d.vehicle_id left join invoices i on i.id = d.invoice_id;
alter view v_challan_list set (security_invoker = on);


create or replace view v_challan_lines as
select ci.id, ci.challan_id, ci.item_id, i.item_code, i.name as item_name, ci.units_per_box, ci.boxes, ci.qty, ci.uom_id, ci.qty_base
  from challan_items ci join items i on i.id = ci.item_id;
alter view v_challan_lines set (security_invoker = on);

create or replace function post_challan_stock(p_challan uuid, p_sign int, p_date date) returns void
language sql as $$
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
  select d.org_id, ci.item_id, d.location_id, 'sale', p_date, p_sign * ci.qty_base, effective_unit_rate(ci.item_id, d.customer_id, d.challan_date), 'delivery_challans', d.id, d.created_by
    from delivery_challans d join challan_items ci on ci.challan_id = d.id where d.id = p_challan;
$$;

create or replace function save_challan(p_header jsonb, p_lines jsonb) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p_header->>'id', '')::uuid; d delivery_challans%rowtype; l jsonb; n int := 0; x record; v_date date;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'A challan needs at least one line'; end if;
  v_date := coalesce(nullif(p_header->>'challan_date', '')::date, current_date);
  if nullif(p_header->>'location_id', '') is null then raise exception 'Pick where the goods leave from'; end if;
  if v_id is null then
    insert into delivery_challans (org_id, challan_no, customer_id, challan_date, location_id, vehicle_id, trip_id, notes, created_by)
    values (v_org, next_doc_no(v_org, 'challan'), (p_header->>'customer_id')::uuid, v_date, (p_header->>'location_id')::uuid,
            nullif(p_header->>'vehicle_id', '')::uuid, nullif(p_header->>'trip_id', '')::uuid, nullif(p_header->>'notes', ''), my_staff_id())
    returning id into v_id;
  else
    select * into d from delivery_challans where id = v_id and org_id = v_org;
    if not found then raise exception 'Challan not found'; end if;
    if d.state <> 'open' then raise exception 'Challan % is %', d.challan_no, d.state; end if;
    perform post_challan_stock(v_id, 1, current_date);   -- goods back, before the new lines go out
    update delivery_challans set customer_id = (p_header->>'customer_id')::uuid, challan_date = v_date, location_id = (p_header->>'location_id')::uuid,
           vehicle_id = nullif(p_header->>'vehicle_id', '')::uuid, notes = nullif(p_header->>'notes', '') where id = v_id;
    delete from challan_items where challan_id = v_id;
  end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    if coalesce((l->>'boxes')::numeric, 0) <= 0 then raise exception 'Line %: boxes must be greater than zero', n; end if;
    select * into x from doc_line((l->>'item_id')::uuid, (l->>'boxes')::numeric, 0);
    if x.units_per_box is null then raise exception 'Line %: item not found', n; end if;
    insert into challan_items (challan_id, item_id, units_per_box, boxes, qty, uom_id, qty_base)
    values (v_id, (l->>'item_id')::uuid, x.units_per_box, (l->>'boxes')::numeric, x.qty, x.uom_id, x.qty_base);
  end loop;
  perform post_challan_stock(v_id, -1, v_date);
  return v_id;
end $$;

create or replace function cancel_challan(p_challan uuid) returns void
language plpgsql as $$
declare d delivery_challans%rowtype;
begin
  select * into d from delivery_challans where id = p_challan;
  if not found then raise exception 'Challan not found'; end if;
  if d.state <> 'open' then raise exception 'Challan % is %', d.challan_no, d.state; end if;
  perform post_challan_stock(p_challan, 1, current_date);
  update delivery_challans set state = 'cancelled' where id = p_challan;
end $$;

/** Bill the challan: a confirmed invoice with the same lines at today's effective rates. */
create or replace function convert_challan(p_challan uuid, p_extra jsonb default '{}'::jsonb) returns uuid
language plpgsql as $$
declare d delivery_challans%rowtype; v_inv uuid; v_lines jsonb; v_date date;
begin
  select * into d from delivery_challans where id = p_challan for update;
  if not found then raise exception 'Challan not found'; end if;
  if d.state <> 'open' then raise exception 'Challan % is %', d.challan_no, d.state; end if;
  v_date := coalesce(nullif(p_extra->>'invoice_date', '')::date, current_date);
  select jsonb_agg(jsonb_build_object('item_id', item_id, 'boxes', boxes, 'rate', coalesce(nullif(x->>'rate', '')::numeric, effective_unit_rate(item_id, d.customer_id, v_date))))
    into v_lines
    from challan_items ci left join jsonb_array_elements(coalesce(p_extra->'rates', '[]'::jsonb)) x on (x->>'item_id')::uuid = ci.item_id
   where ci.challan_id = p_challan;
  v_inv := save_invoice(jsonb_build_object('customer_id', d.customer_id, 'invoice_date', v_date, 'location_id', d.location_id, 'vehicle_id', d.vehicle_id,
             'transport_name', p_extra->>'transport_name', 'lr_no', p_extra->>'lr_no', 'lr_date', p_extra->>'lr_date', 'freight', coalesce(p_extra->>'freight', '0'),
             'discount', coalesce(p_extra->>'discount', '0'), 'notes', format('Against challan %s', d.challan_no)), v_lines);
  perform post_challan_stock(p_challan, 1, v_date);     -- the invoice takes the stock out from here
  perform set_invoice_status(v_inv, 'confirmed');
  update delivery_challans set state = 'converted', invoice_id = v_inv where id = p_challan;
  return v_inv;
end $$;

-- ------------------------------------------------------------
-- 8. Purchase returns (debit notes): stock out, Dr Creditors /
--    Cr Purchases, supplier payable comes down.
-- ------------------------------------------------------------

create or replace view v_purchase_return_list as
select r.id, r.org_id, r.return_no, r.return_date, r.supplier_id, s.name as supplier_name, r.purchase_id, p.bill_no, r.location_id, l.name as location_name, r.total, r.notes, r.created_by, r.created_at,
       (select count(*) from purchase_return_items x where x.return_id = r.id) as line_count
  from purchase_returns r join suppliers s on s.id = r.supplier_id left join purchases p on p.id = r.purchase_id left join stock_locations l on l.id = r.location_id;
alter view v_purchase_return_list set (security_invoker = on);

create or replace view v_purchase_return_lines as
select ri.id, ri.return_id, ri.item_id, i.item_code, i.name as item_name, ri.qty, ri.uom_id, u.code as uom_code, ri.qty_base, ri.rate, ri.amount
  from purchase_return_items ri join items i on i.id = ri.item_id left join uoms u on u.id = ri.uom_id;
alter view v_purchase_return_lines set (security_invoker = on);

create or replace function save_purchase_return(p_header jsonb, p_lines jsonb) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid; l jsonb; n int := 0; v_total numeric := 0; v_qty numeric; v_rate numeric; v_uom uuid; v_base numeric; v_sup uuid; v_date date; v_loc uuid; v_no text; v_sup_name text;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'A purchase return needs at least one line'; end if;
  v_sup := (p_header->>'supplier_id')::uuid; v_loc := nullif(p_header->>'location_id', '')::uuid;
  if v_loc is null then raise exception 'Pick the location the goods leave from'; end if;
  select name into v_sup_name from suppliers where id = v_sup and org_id = v_org;
  if v_sup_name is null then raise exception 'Supplier not found'; end if;
  v_date := coalesce(nullif(p_header->>'return_date', '')::date, current_date);
  v_no := next_doc_no(v_org, 'purchase_return');
  insert into purchase_returns (org_id, return_no, supplier_id, purchase_id, return_date, location_id, notes, created_by)
  values (v_org, v_no, v_sup, nullif(p_header->>'purchase_id', '')::uuid, v_date, v_loc, nullif(p_header->>'notes', ''), my_staff_id())
  returning id into v_id;
  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    v_qty := coalesce((l->>'qty')::numeric, 0);
    if v_qty <= 0 then raise exception 'Line %: quantity must be greater than zero', n; end if;
    v_rate := coalesce(nullif(l->>'rate', '')::numeric, (select purchase_rate from items where id = (l->>'item_id')::uuid), 0);
    v_uom := coalesce(nullif(l->>'uom_id', '')::uuid, (select base_uom_id from items where id = (l->>'item_id')::uuid));
    v_base := to_base_qty((l->>'item_id')::uuid, v_qty, v_uom);
    insert into purchase_return_items (return_id, item_id, qty, uom_id, qty_base, rate, amount)
    values (v_id, (l->>'item_id')::uuid, v_qty, v_uom, v_base, v_rate, round(v_qty * v_rate, 2));
    v_total := v_total + round(v_qty * v_rate, 2);
  end loop;
  update purchase_returns set total = round(v_total, 2) where id = v_id;
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
  select v_org, ri.item_id, v_loc, 'purchase_return', v_date, -ri.qty_base, ri.rate, 'purchase_returns', v_id, my_staff_id()
    from purchase_return_items ri where ri.return_id = v_id;
  perform post_journal(v_org, v_date, format('Purchase return %s — %s', v_no, v_sup_name), 'purchase_returns', v_id,
    jsonb_build_array(jsonb_build_object('account', 'CREDITORS', 'debit', round(v_total, 2)), jsonb_build_object('account', 'PURCHASES', 'credit', round(v_total, 2))));
  return v_id;
end $$;

create or replace view v_supplier_list as
select s.*, coalesce((select sum(total - paid_amount) from purchases p where p.supplier_id = s.id), 0)
             - coalesce((select sum(amount) from payments pm where pm.supplier_id = s.id), 0)
             - coalesce((select sum(total) from purchase_returns pr where pr.supplier_id = s.id), 0)
             + s.opening_balance as payable
from suppliers s;
alter view v_supplier_list set (security_invoker = on);
