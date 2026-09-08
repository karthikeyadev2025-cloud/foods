-- ============================================================
-- JYOTHI FOODS ERP — 16: INVENTORY DEPTH (T9)
-- Batches with expiry (FEFO), barcodes, godown transfers and
-- physical stock counts. The ledger stays append-only: every
-- count variance and every transfer is a new row.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tables + module-gated RLS (module 'stock').
-- ------------------------------------------------------------
create table if not exists stock_transfers (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  transfer_no   text,
  from_location uuid not null references stock_locations(id),
  to_location   uuid not null references stock_locations(id),
  txn_date      date not null default current_date,
  notes         text,
  created_by    uuid references staff(id),
  created_at    timestamptz not null default now()
);
create table if not exists stock_transfer_items (
  id            uuid primary key default gen_random_uuid(),
  transfer_id   uuid not null references stock_transfers(id) on delete cascade,
  item_id       uuid not null references items(id),
  units_per_box numeric(12,3) not null,
  boxes         numeric(16,3) not null,
  qty_base      numeric(16,3) not null
);
create table if not exists stock_counts (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  count_no    text,
  location_id uuid not null references stock_locations(id),
  section_id  uuid references sections(id),
  count_date  date not null default current_date,
  status      text not null default 'open' check (status in ('open', 'posted', 'cancelled')),
  notes       text,
  created_by  uuid references staff(id),
  posted_by   uuid references staff(id),
  posted_at   timestamptz,
  created_at  timestamptz not null default now()
);
create table if not exists stock_count_items (
  id            uuid primary key default gen_random_uuid(),
  count_id      uuid not null references stock_counts(id) on delete cascade,
  item_id       uuid not null references items(id),
  units_per_box numeric(12,3) not null,
  system_base   numeric(16,3) not null default 0,
  counted_boxes numeric(16,3),
  counted_base  numeric(16,3),
  posted_base   numeric(16,3),
  unique (count_id, item_id)
);
alter table stock_transfers enable row level security;
alter table stock_transfer_items enable row level security;
alter table stock_counts enable row level security;
alter table stock_count_items enable row level security;
alter table item_batches add column if not exists notes text, add column if not exists created_at timestamptz not null default now();
alter table item_barcodes add column if not exists created_at timestamptz not null default now();

do $$
declare r record;
begin
  for r in select * from (values ('stock_transfers', 'stock'), ('stock_counts', 'stock'), ('item_batches', 'stock'), ('item_barcodes', 'items')) as t(tbl, module) loop
    execute format('drop policy if exists org_read on %I', r.tbl);
    execute format('drop policy if exists org_write on %I', r.tbl);
    execute format('drop policy if exists mod_insert on %I', r.tbl);
    execute format('drop policy if exists mod_update on %I', r.tbl);
    execute format('drop policy if exists mod_delete on %I', r.tbl);
    execute format('create policy org_read on %I for select using (org_id = my_org_id())', r.tbl);
    execute format('create policy mod_insert on %I for insert with check (org_id = my_org_id() and can_edit(%L))', r.tbl, r.module);
    execute format('create policy mod_update on %I for update using (org_id = my_org_id() and can_edit(%L)) with check (org_id = my_org_id() and can_edit(%L))', r.tbl, r.module, r.module);
    execute format('create policy mod_delete on %I for delete using (org_id = my_org_id() and can_delete(%L))', r.tbl, r.module);
  end loop;
end $$;
drop policy if exists child_scope on stock_transfer_items;
create policy child_scope on stock_transfer_items for all
  using (exists (select 1 from stock_transfers t where t.id = transfer_id and t.org_id = my_org_id()))
  with check (exists (select 1 from stock_transfers t where t.id = transfer_id and t.org_id = my_org_id()));
drop policy if exists child_scope on stock_count_items;
create policy child_scope on stock_count_items for all
  using (exists (select 1 from stock_counts c where c.id = count_id and c.org_id = my_org_id()))
  with check (exists (select 1 from stock_counts c where c.id = count_id and c.org_id = my_org_id()));

-- ------------------------------------------------------------
-- 2. Batches & expiry. A batch is born when production closes;
--    its expiry is the item's shelf life from the making date.
--    Balances are FEFO: whatever left the item is assumed to have
--    come from the earliest-expiring batch first.
-- ------------------------------------------------------------
create or replace function close_production_batch(p_batch uuid)
returns void language plpgsql as $$
declare b production_batches%rowtype; it items%rowtype; v_qty numeric; v_ing numeric; v_batch uuid;
begin
  if my_role() = 'chief' then raise exception 'Chiefs enter actuals; the production head closes the batch'; end if;
  select * into b from production_batches where id = p_batch and org_id = my_org_id() for update;
  if not found then raise exception 'Batch not found'; end if;
  if b.status <> 'open' then raise exception 'Batch % is already %', b.batch_no, b.status; end if;
  if b.location_id is null then raise exception 'Batch % has no stock location', b.batch_no; end if;
  if b.actual_boxes <= 0 then raise exception 'Enter the actual boxes produced before closing'; end if;
  select * into it from items where id = b.item_id;

  update batch_ingredients set amount = round(actual_qty * rate, 2) where batch_id = p_batch;
  select coalesce(sum(amount), 0) into v_ing from batch_ingredients where batch_id = p_batch;

  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
  select b.org_id, bi.ingredient_id, b.location_id, 'production_consume', b.production_date,
         -to_base_qty(bi.ingredient_id, bi.actual_qty, bi.uom_id), bi.rate, 'production_batches', b.id, my_staff_id()
  from batch_ingredients bi where bi.batch_id = p_batch and bi.actual_qty <> 0;

  -- the item batch: same number as the production batch, expiry from the shelf life
  insert into item_batches (org_id, item_id, batch_no, mfg_date, expiry_date, production_batch_id)
  values (b.org_id, b.item_id, b.batch_no, b.production_date,
          case when it.shelf_life_days is not null then b.production_date + it.shelf_life_days end, b.id)
  on conflict (org_id, item_id, batch_no) do update set mfg_date = excluded.mfg_date, expiry_date = excluded.expiry_date, production_batch_id = excluded.production_batch_id
  returning id into v_batch;

  v_qty := pieces_to_uom(b.item_id, b.actual_pieces, it.base_uom_id);
  insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by, batch_id, batch_no)
  values (b.org_id, b.item_id, b.location_id, 'production_in', b.production_date, v_qty,
          case when v_qty > 0 then round((v_ing + b.labour_cost) / v_qty, 2) else 0 end,
          'production_batches', b.id, my_staff_id(), v_batch, b.batch_no);

  update production_batches
     set status = 'closed', ingredient_cost = v_ing, total_cost = round(v_ing + labour_cost, 2), closed_at = now()
   where id = p_batch;
end $$;

/**
 * Per batch: produced, what FEFO says is gone, what is left. Consumption of an item =
 * everything produced into batches minus the item's stock on hand; it is charged to the
 * earliest-expiring batches first. Items with untracked (opening / purchased) stock keep
 * it outside the batches.
 */
create or replace function batch_balances(p_org uuid, p_item uuid default null)
returns table (batch_id uuid, item_id uuid, item_code text, item_name text, units_per_box integer, batch_no text, mfg_date date, expiry_date date,
               produced_base numeric, consumed_base numeric, remaining_base numeric, remaining_boxes numeric, days_to_expiry integer, is_expired boolean, is_near_expiry boolean)
language sql stable as $$
  with b as (
    select ib.id, ib.item_id, ib.batch_no, ib.mfg_date, ib.expiry_date,
           coalesce((select sum(l.qty_base) from stock_ledger l where l.batch_id = ib.id and l.qty_base > 0), 0) as produced
      from item_batches ib where ib.org_id = p_org and (p_item is null or ib.item_id = p_item)),
  onhand as (
    select l.item_id, sum(l.qty_base) as qty from stock_ledger l where l.org_id = p_org and (p_item is null or l.item_id = p_item) group by l.item_id),
  cons as (
    select b.item_id, greatest(sum(b.produced) - coalesce(max(o.qty), 0), 0) as consumed
      from b left join onhand o on o.item_id = b.item_id group by b.item_id),
  fefo as (
    select b.*, sum(b.produced) over (partition by b.item_id order by b.expiry_date nulls last, b.mfg_date, b.batch_no rows unbounded preceding) as cum
      from b)
  select f.id, f.item_id, i.item_code, i.name, i.units_per_box, f.batch_no, f.mfg_date, f.expiry_date,
         f.produced,
         least(f.produced, greatest(c.consumed - (f.cum - f.produced), 0)) as consumed_base,
         f.produced - least(f.produced, greatest(c.consumed - (f.cum - f.produced), 0)) as remaining_base,
         round((f.produced - least(f.produced, greatest(c.consumed - (f.cum - f.produced), 0))) / nullif(i.units_per_box, 0), 3),
         (f.expiry_date - current_date)::int,
         f.expiry_date is not null and f.expiry_date < current_date,
         f.expiry_date is not null and f.expiry_date >= current_date and f.expiry_date <= current_date + 7
    from fefo f join items i on i.id = f.item_id join cons c on c.item_id = f.item_id
   order by i.item_code, f.expiry_date nulls last, f.mfg_date;
$$;

/** What is expiring or expired and still on the shelf. */
create or replace function expiry_report(p_org uuid, p_days int default 30)
returns table (batch_id uuid, item_id uuid, item_code text, item_name text, batch_no text, mfg_date date, expiry_date date, remaining_boxes numeric, days_to_expiry integer, is_expired boolean, value_at_rate numeric)
language sql stable as $$
  select b.batch_id, b.item_id, b.item_code, b.item_name, b.batch_no, b.mfg_date, b.expiry_date, b.remaining_boxes, b.days_to_expiry, b.is_expired,
         round(b.remaining_base * coalesce(i.unit_rate, 0), 2)
    from batch_balances(p_org) b join items i on i.id = b.item_id
   where b.remaining_base > 0 and b.expiry_date is not null and b.expiry_date <= current_date + p_days
   order by b.expiry_date, b.item_code;
$$;

/** FEFO pick list for loading N boxes of an item: earliest expiry first. */
create or replace function fefo_suggest(p_item uuid, p_boxes numeric)
returns table (batch_no text, expiry_date date, take_boxes numeric, remaining_boxes numeric)
language plpgsql stable as $$
declare r record; v_left numeric := p_boxes; v_org uuid;
begin
  select org_id into v_org from items where id = p_item;
  for r in select * from batch_balances(v_org, p_item) bb where bb.remaining_base > 0 order by bb.expiry_date nulls last, bb.mfg_date loop
    exit when v_left <= 0;
    batch_no := r.batch_no; expiry_date := r.expiry_date; remaining_boxes := r.remaining_boxes;
    take_boxes := least(v_left, r.remaining_boxes);
    v_left := v_left - take_boxes;
    return next;
  end loop;
end $$;

create or replace view v_item_batches as
select ib.*, i.item_code, i.name as item_name, pb.batch_no as production_batch_no,
       coalesce((select sum(l.qty_base) from stock_ledger l where l.batch_id = ib.id and l.qty_base > 0), 0) as produced_base
  from item_batches ib join items i on i.id = ib.item_id left join production_batches pb on pb.id = ib.production_batch_id;
alter view v_item_batches set (security_invoker = on);

-- ------------------------------------------------------------
-- 3. Barcodes: one per item per pack level (box or unit),
--    EAN-13 with a check digit so any scanner reads it.
-- ------------------------------------------------------------
create or replace function ean13_check(p_body text) returns text
language plpgsql immutable as $$
declare s int := 0; i int; d int;
begin
  if p_body !~ '^\d{12}$' then raise exception 'EAN-13 needs 12 digits, got %', p_body; end if;
  for i in 1..12 loop
    d := substr(p_body, i, 1)::int;
    s := s + d * case when i % 2 = 0 then 3 else 1 end;
  end loop;
  return p_body || ((10 - s % 10) % 10)::text;
end $$;

/** Create the missing barcodes: a box code and a unit code per active finished item (or one item). */
create or replace function generate_barcodes(p_item uuid default null) returns integer
language plpgsql as $$
declare v_org uuid := my_org_id(); it record; n int := 0; v_seq text; v_box uuid;
begin
  for it in select i.id, i.base_uom_id from items i where i.org_id = v_org and i.is_active and i.type = 'finished_good' and (p_item is null or i.id = p_item) order by i.item_code loop
    select id into v_box from uoms where org_id = v_org and basis = 'box' and is_active order by sort_order limit 1;
    if not exists (select 1 from item_barcodes where item_id = it.id and uom_id is null) then
      v_seq := regexp_replace(next_doc_no(v_org, 'barcode'), '\D', '', 'g');
      insert into item_barcodes (org_id, item_id, barcode, uom_id) values (v_org, it.id, ean13_check('2' || lpad(v_seq, 10, '0') || '1'), null);
      n := n + 1;
    end if;
    if not exists (select 1 from item_barcodes where item_id = it.id and uom_id = it.base_uom_id) then
      v_seq := regexp_replace(next_doc_no(v_org, 'barcode'), '\D', '', 'g');
      insert into item_barcodes (org_id, item_id, barcode, uom_id) values (v_org, it.id, ean13_check('2' || lpad(v_seq, 10, '0') || '2'), it.base_uom_id);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace view v_item_barcodes as
select bc.*, i.item_code, i.name as item_name, i.units_per_box, i.unit_rate, i.mrp_per_piece, i.pieces_per_unit, u.code as uom_code,
       case when bc.uom_id is null then 'box' else 'unit' end as level
  from item_barcodes bc join items i on i.id = bc.item_id left join uoms u on u.id = bc.uom_id;
alter view v_item_barcodes set (security_invoker = on);

/** Scanner lookup: the item, and whether the code is for a box or a single unit. */
create or replace function item_by_barcode(p_code text)
returns table (item_id uuid, level text)
language sql stable as $$
  select bc.item_id, case when bc.uom_id is null then 'box' else 'unit' end
    from item_barcodes bc join items i on i.id = bc.item_id
   where bc.org_id = my_org_id() and bc.barcode = regexp_replace(coalesce(p_code, ''), '\D', '', 'g') and i.is_active
   limit 1;
$$;

-- ------------------------------------------------------------
-- 4. Godown transfers: location → location, one note.
-- ------------------------------------------------------------
create or replace function save_stock_transfer(p_header jsonb, p_lines jsonb) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid; v_from uuid; v_to uuid; v_date date; l jsonb; it items%rowtype; q numeric; n int := 0; v_no text; v_fn text; v_tn text;
begin
  v_from := (p_header->>'from_location')::uuid; v_to := (p_header->>'to_location')::uuid;
  if v_from is null or v_to is null or v_from = v_to then raise exception 'Pick two different locations'; end if;
  select name into v_fn from stock_locations where id = v_from and org_id = v_org;
  select name into v_tn from stock_locations where id = v_to and org_id = v_org;
  if v_fn is null or v_tn is null then raise exception 'Location not found'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Nothing to transfer'; end if;
  v_date := coalesce(nullif(p_header->>'txn_date', '')::date, current_date);
  v_no := next_doc_no(v_org, 'stock_transfer');
  insert into stock_transfers (org_id, transfer_no, from_location, to_location, txn_date, notes, created_by)
  values (v_org, v_no, v_from, v_to, v_date, nullif(p_header->>'notes', ''), my_staff_id()) returning id into v_id;
  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    select * into it from items where id = (l->>'item_id')::uuid and org_id = v_org;
    if not found then raise exception 'Line %: item not found', n; end if;
    q := round(coalesce((l->>'boxes')::numeric, 0) * it.units_per_box, 3);
    if q <= 0 then raise exception 'Line % (%): boxes must be greater than zero', n, it.item_code; end if;
    insert into stock_transfer_items (transfer_id, item_id, units_per_box, boxes, qty_base) values (v_id, it.id, it.units_per_box, (l->>'boxes')::numeric, q);
    insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
    values (v_org, it.id, v_from, 'transfer', v_date, -q, it.unit_rate, 'stock_transfers', v_id, my_staff_id()),
           (v_org, it.id, v_to,   'transfer', v_date,  q, it.unit_rate, 'stock_transfers', v_id, my_staff_id());
  end loop;
  return v_id;
end $$;

create or replace view v_stock_transfers as
select t.*, f.name as from_name, g.name as to_name, st.full_name as created_by_name,
       (select count(*) from stock_transfer_items x where x.transfer_id = t.id) as line_count,
       (select coalesce(sum(boxes), 0) from stock_transfer_items x where x.transfer_id = t.id) as total_boxes
  from stock_transfers t join stock_locations f on f.id = t.from_location join stock_locations g on g.id = t.to_location left join staff st on st.id = t.created_by;
alter view v_stock_transfers set (security_invoker = on);

create or replace view v_stock_transfer_lines as
select x.*, i.item_code, i.name as item_name, pt.code as pack_code
  from stock_transfer_items x join items i on i.id = x.item_id left join pack_types pt on pt.id = i.pack_type_id;
alter view v_stock_transfer_lines set (security_invoker = on);

-- ------------------------------------------------------------
-- 5. Physical stock count: snapshot the system figure, count,
--    post the variance as adjustment rows.
-- ------------------------------------------------------------
create or replace function location_stock_base(p_item uuid, p_location uuid, p_date date default current_date) returns numeric
language sql stable as $$
  select coalesce(sum(qty_base), 0) from stock_ledger where item_id = p_item and location_id = p_location and txn_date <= p_date;
$$;

/** A count sheet for one location (optionally one section): every active finished item with the system figure frozen now. */
create or replace function open_stock_count(p_location uuid, p_date date default current_date, p_section uuid default null, p_notes text default null) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid; n int;
begin
  if not exists (select 1 from stock_locations where id = p_location and org_id = v_org) then raise exception 'Location not found'; end if;
  if exists (select 1 from stock_counts where org_id = v_org and location_id = p_location and status = 'open' and (p_section is null or section_id = p_section)) then
    raise exception 'A count is already open for this location; post or cancel it first';
  end if;
  insert into stock_counts (org_id, count_no, location_id, section_id, count_date, notes, created_by)
  values (v_org, next_doc_no(v_org, 'stock_count'), p_location, p_section, p_date, p_notes, my_staff_id()) returning id into v_id;
  insert into stock_count_items (count_id, item_id, units_per_box, system_base)
  select v_id, i.id, i.units_per_box, location_stock_base(i.id, p_location, p_date)
    from items i where i.org_id = v_org and i.is_active and i.type = 'finished_good' and (p_section is null or i.section_id = p_section);
  get diagnostics n = row_count;
  if n = 0 then raise exception 'No items to count'; end if;
  return v_id;
end $$;

/** Enter counted boxes: [{item_id, counted_boxes}] — null clears a line back to "not counted". */
create or replace function update_stock_count(p_count uuid, p_lines jsonb) returns integer
language plpgsql as $$
declare c stock_counts%rowtype; l jsonb; n int := 0; v_boxes numeric;
begin
  select * into c from stock_counts where id = p_count and org_id = my_org_id();
  if not found then raise exception 'Count not found'; end if;
  if c.status <> 'open' then raise exception 'Count % is %', c.count_no, c.status; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    v_boxes := nullif(l->>'counted_boxes', '')::numeric;
    if v_boxes is not null and v_boxes < 0 then raise exception 'Counted boxes cannot be negative'; end if;
    update stock_count_items set counted_boxes = v_boxes, counted_base = case when v_boxes is null then null else round(v_boxes * units_per_box, 3) end
     where count_id = p_count and item_id = (l->>'item_id')::uuid;
    n := n + 1;
  end loop;
  return n;
end $$;

/**
 * Post: for every counted line the variance against the LIVE system figure (movements since
 * the sheet was opened are not double-counted) becomes an 'adjustment' row. Uncounted lines
 * are left alone. Returns how many adjustments were posted.
 */
create or replace function post_stock_count(p_count uuid) returns integer
language plpgsql as $$
declare c stock_counts%rowtype; l record; v_live numeric; v_var numeric; n int := 0;
begin
  select * into c from stock_counts where id = p_count and org_id = my_org_id() for update;
  if not found then raise exception 'Count not found'; end if;
  if c.status <> 'open' then raise exception 'Count % is %', c.count_no, c.status; end if;
  if not exists (select 1 from stock_count_items where count_id = p_count and counted_base is not null) then raise exception 'Nothing has been counted yet'; end if;
  for l in select sci.*, i.unit_rate from stock_count_items sci join items i on i.id = sci.item_id where sci.count_id = p_count and sci.counted_base is not null loop
    v_live := location_stock_base(l.item_id, c.location_id);
    v_var := round(l.counted_base - v_live, 3);
    update stock_count_items set posted_base = v_var where id = l.id;
    if v_var <> 0 then
      insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
      values (c.org_id, l.item_id, c.location_id, 'adjustment', c.count_date, v_var, l.unit_rate, 'stock_counts', c.id, my_staff_id());
      n := n + 1;
    end if;
  end loop;
  update stock_counts set status = 'posted', posted_by = my_staff_id(), posted_at = now() where id = p_count;
  return n;
end $$;

create or replace function cancel_stock_count(p_count uuid) returns void
language plpgsql as $$
begin
  update stock_counts set status = 'cancelled' where id = p_count and org_id = my_org_id() and status = 'open';
  if not found then raise exception 'Count not found or already closed'; end if;
end $$;

create or replace view v_stock_counts as
select c.*, l.name as location_name, s.name as section_name, st.full_name as created_by_name, pst.full_name as posted_by_name,
       (select count(*) from stock_count_items x where x.count_id = c.id) as line_count,
       (select count(*) from stock_count_items x where x.count_id = c.id and x.counted_base is not null) as counted_count,
       (select count(*) from stock_count_items x where x.count_id = c.id and coalesce(x.posted_base, x.counted_base - x.system_base) <> 0 and x.counted_base is not null) as variance_count
  from stock_counts c join stock_locations l on l.id = c.location_id left join sections s on s.id = c.section_id
  left join staff st on st.id = c.created_by left join staff pst on pst.id = c.posted_by;
alter view v_stock_counts set (security_invoker = on);

create or replace view v_stock_count_lines as
select x.*, i.item_code, i.name as item_name, pt.code as pack_code, sec.name as section_name, sec.sort_order as section_sort, i.unit_rate,
       round(x.system_base / nullif(x.units_per_box, 0), 3) as system_boxes,
       round(coalesce(x.posted_base, x.counted_base - x.system_base) / nullif(x.units_per_box, 0), 3) as variance_boxes,
       round(coalesce(x.posted_base, x.counted_base - x.system_base) * coalesce(i.unit_rate, 0), 2) as variance_value
  from stock_count_items x join items i on i.id = x.item_id left join pack_types pt on pt.id = i.pack_type_id left join sections sec on sec.id = i.section_id;
alter view v_stock_count_lines set (security_invoker = on);

-- ------------------------------------------------------------
-- 6. Dashboard: batches expiring within a week.
-- ------------------------------------------------------------
create or replace function dashboard_summary(p_org uuid, p_date date default current_date)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'sales_today',      (select coalesce(sum(total),0) from invoices where org_id=p_org and invoice_date=p_date and status<>'cancelled'),
    'sales_mtd',        (select coalesce(sum(total),0) from invoices where org_id=p_org and status<>'cancelled' and invoice_date >= date_trunc('month',p_date)),
    'collection_today', (select coalesce(sum(total_amount),0) from receipts where org_id=p_org and receipt_date=p_date),
    'total_outstanding',(select coalesce(sum(outstanding),0) from v_customer_outstanding where org_id=p_org),
    'invoices_today',   (select count(*) from invoices where org_id=p_org and invoice_date=p_date),
    'low_stock_items',  (select count(*) from v_stock_on_hand where org_id=p_org and is_low),
    'negative_stock',   (select count(*) from v_stock_on_hand where org_id=p_org and is_negative),
    'vehicles_out',     (select count(*) from vehicle_trips where org_id=p_org and trip_date=p_date and status='dispatched'),
    'batches_open',     (select count(*) from production_batches where org_id=p_org and status='open'),
    'pending_orders',   (select count(*) from inbound_orders where org_id=p_org and status='new'),
    'cash_balance',     (select coalesce(sum(balance),0) from v_cash_bank_accounts where org_id=p_org and kind='cash' and is_active),
    'bank_balance',     (select coalesce(sum(balance),0) from v_cash_bank_accounts where org_id=p_org and kind<>'cash' and is_active),
    'cheques_in_hand',  (select coalesce(sum(amount),0) from cheques where org_id=p_org and direction='received' and state in ('in_hand','deposited')),
    'cheques_due',      (select count(*) from v_cheques where org_id=p_org and is_due),
    'payables',         (select coalesce(sum(payable),0) from v_supplier_list where org_id=p_org),
    'expiring_batches', (select count(*) from expiry_report(p_org, 7)),
    'open_counts',      (select count(*) from stock_counts where org_id=p_org and status='open')
  );
$$;
