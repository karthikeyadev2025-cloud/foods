-- ============================================================
-- JYOTHI FOODS ERP — 05: FIXES FOUND BY db/tests BEFORE FIRST DEPLOY
--
-- Every change here was caught by db/tests/01_quotation.sql or
-- db/tests/02_rls.sql running against 01–04 on a clean Postgres 16.
-- Runs after 03_rls.sql.
-- ============================================================

-- ------------------------------------------------------------
-- 1. audit_log had no RLS at all — any authenticated user could
--    read every org's audit trail. Owners/admins read their own org.
-- ------------------------------------------------------------
alter table audit_log enable row level security;
drop policy if exists audit_read on audit_log;
create policy audit_read on audit_log for select
  using (org_id = my_org_id() and has_role('owner','admin'));
drop policy if exists audit_insert on audit_log;
create policy audit_insert on audit_log for insert
  with check (org_id = my_org_id());

-- ------------------------------------------------------------
-- 2. The 04 reporting views ran with the definer's rights, which
--    bypasses RLS on their base tables (cross-org day book, trial
--    balance, cash balances, item profit). 03 already did this for
--    the 02 views; these four were missed.
-- ------------------------------------------------------------
alter view v_day_book         set (security_invoker = on);
alter view v_trial_balance    set (security_invoker = on);
alter view v_account_balances set (security_invoker = on);
alter view v_item_profit      set (security_invoker = on);

-- ------------------------------------------------------------
-- 3. Trade terms are "editable per org" but orgs had no update
--    policy. The owner may edit their own org row.
-- ------------------------------------------------------------
drop policy if exists org_owner_update on orgs;
create policy org_owner_update on orgs for update
  using (id = my_org_id() and has_role('owner'))
  with check (id = my_org_id());

-- ------------------------------------------------------------
-- 4. Invoice line: units_per_box defaulted to 1, so the trigger's
--    "snapshot from the master if zero" never fired and every line
--    computed Qty = boxes × 1. The master is the ONLY source on
--    insert; on update the stored snapshot is kept. Rate defaults
--    to the customer's effective rate when not typed.
-- ------------------------------------------------------------
alter table invoice_items alter column units_per_box drop default;

create or replace function trg_invoice_line() returns trigger language plpgsql as $$
declare it items%rowtype; inv invoices%rowtype;
begin
  select * into it from items where id = new.item_id;
  if not found then raise exception 'Item % not found', new.item_id; end if;

  if tg_op = 'INSERT' then
    new.units_per_box := it.units_per_box;          -- snapshot at billing time
  else
    new.units_per_box := old.units_per_box;         -- history never re-quantifies
  end if;

  new.uom_id := coalesce(new.uom_id, it.base_uom_id);

  if new.rate is null then
    select * into inv from invoices where id = new.invoice_id;
    new.rate := effective_unit_rate(new.item_id, inv.customer_id, inv.invoice_date);
  end if;

  new.qty      := new.boxes * new.units_per_box;
  new.qty_base := to_base_qty(new.item_id, new.qty, new.uom_id);
  new.amount   := round(new.qty * new.rate, 2);
  return new;
end $$;

-- Lines may only change while the invoice is a draft.
create or replace function trg_invoice_items_guard() returns trigger language plpgsql as $$
declare v_status invoice_status;
begin
  select status into v_status from invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if v_status is distinct from 'draft' then
    raise exception 'Invoice is %; lines can only be changed while it is a draft', v_status;
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists t_invoice_items_guard on invoice_items;
create trigger t_invoice_items_guard before insert or update or delete on invoice_items
  for each row execute function trg_invoice_items_guard();

-- ------------------------------------------------------------
-- 5. Nothing maintained invoices.subtotal / total, so outstanding
--    and the dashboard were always zero. Totals follow the lines.
-- ------------------------------------------------------------
create or replace function recompute_invoice_totals(p_invoice uuid)
returns void language sql as $$
  update invoices i
     set subtotal = s.amt,
         total    = round(s.amt - i.discount + i.round_off, 2)
    from (select coalesce(sum(amount), 0) as amt from invoice_items where invoice_id = p_invoice) s
   where i.id = p_invoice;
$$;

create or replace function trg_invoice_items_totals() returns trigger language plpgsql as $$
begin
  perform recompute_invoice_totals(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;

drop trigger if exists t_invoice_items_totals on invoice_items;
create trigger t_invoice_items_totals after insert or update or delete on invoice_items
  for each row execute function trg_invoice_items_totals();

create or replace function trg_invoice_total() returns trigger language plpgsql as $$
begin
  new.total := round(new.subtotal - new.discount + new.round_off, 2);
  return new;
end $$;

drop trigger if exists t_invoice_total on invoices;
create trigger t_invoice_total before insert or update of subtotal, discount, round_off on invoices
  for each row execute function trg_invoice_total();

-- ------------------------------------------------------------
-- 6. qty_base filler tolerated no null uom — default to the item's
--    base uom so a rate-difference line with qty 0 does not error.
-- ------------------------------------------------------------
create or replace function trg_fill_qty_base() returns trigger language plpgsql as $$
begin
  new.uom_id   := coalesce(new.uom_id, (select base_uom_id from items where id = new.item_id));
  new.qty_base := to_base_qty(new.item_id, new.qty, new.uom_id);
  return new;
end $$;

-- ------------------------------------------------------------
-- 7. Posting was "DELETE the old ledger rows, INSERT again". Under
--    RLS there is no delete policy on stock_ledger, so the DELETE
--    silently removed nothing and every status change posted the
--    sale AGAIN (confirm → dispatch doubled the stock deduction).
--    The ledger is append-only: post once, reverse with a row.
-- ------------------------------------------------------------
create or replace function post_invoice_stock(p_invoice uuid)
returns void language plpgsql as $$
declare inv invoices%rowtype; n_out int; n_back int;
begin
  select * into inv from invoices where id = p_invoice;
  if not found then return; end if;

  select count(*) filter (where qty_base < 0), count(*) filter (where qty_base > 0)
    into n_out, n_back
    from stock_ledger where ref_table = 'invoices' and ref_id = p_invoice;

  if inv.status in ('confirmed','dispatched','delivered') then
    if n_out = n_back then                          -- never posted, or posted and reversed
      insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
      select inv.org_id, ii.item_id, inv.location_id, 'sale', inv.invoice_date,
             -ii.qty_base, ii.rate, 'invoices', inv.id, inv.created_by
      from invoice_items ii where ii.invoice_id = p_invoice;
    end if;
  elsif inv.status = 'cancelled' then
    if n_out > n_back then                          -- posted and not yet reversed
      insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
      select inv.org_id, ii.item_id, inv.location_id, 'sale', current_date,
             ii.qty_base, ii.rate, 'invoices', inv.id, inv.created_by
      from invoice_items ii where ii.invoice_id = p_invoice;
    end if;
  end if;
end $$;

create or replace function post_purchase_stock(p_purchase uuid)
returns void language plpgsql as $$
declare p purchases%rowtype;
begin
  select * into p from purchases where id = p_purchase;
  if not found then return; end if;
  if exists (select 1 from stock_ledger where ref_table = 'purchases' and ref_id = p_purchase) then
    raise exception 'Purchase % is already posted to stock. Corrections are adjustment rows.', p.bill_no;
  end if;
  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select p.org_id, pi.item_id, p.location_id, 'purchase', p.bill_date,
         pi.qty_base, pi.rate, 'purchases', p.id, p.created_by
  from purchase_items pi where pi.purchase_id = p_purchase;
end $$;

create or replace function post_return_stock(p_return uuid)
returns void language plpgsql as $$
declare r sales_returns%rowtype;
begin
  select * into r from sales_returns where id = p_return;
  if not found then return; end if;
  if r.kind = 'rate_difference' or r.location_id is null then return; end if;
  if exists (select 1 from stock_ledger where ref_table = 'sales_returns' and ref_id = p_return) then
    raise exception 'Return % is already posted to stock. Corrections are adjustment rows.', r.return_no;
  end if;

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select r.org_id, ri.item_id, r.location_id,
         case when r.kind = 'fresh_return' then 'sale_return'::stock_txn_type
              else 'damage'::stock_txn_type end,
         r.return_date,
         case when r.kind = 'fresh_return' then ri.qty_base else 0 end,
         coalesce(ri.new_rate, ri.old_rate, 0), 'sales_returns', r.id, r.created_by
  from sales_return_items ri where ri.return_id = p_return;
end $$;

create or replace function close_production_batch(p_batch uuid)
returns void language plpgsql as $$
declare b production_batches%rowtype; it items%rowtype; v_qty numeric;
begin
  select * into b from production_batches where id = p_batch;
  if not found then return; end if;
  if b.status <> 'open' then
    raise exception 'Batch % is already %', b.batch_no, b.status;
  end if;
  if b.location_id is null then
    raise exception 'Batch % has no stock location', b.batch_no;
  end if;
  select * into it from items where id = b.item_id;

  update batch_ingredients set amount = actual_qty * rate where batch_id = p_batch;

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id)
  select b.org_id, bi.ingredient_id, b.location_id, 'production_consume', b.production_date,
         -to_base_qty(bi.ingredient_id, bi.actual_qty, bi.uom_id), bi.rate,
         'production_batches', b.id
  from batch_ingredients bi where bi.batch_id = p_batch;

  v_qty := pieces_to_uom(b.item_id, b.actual_pieces, it.base_uom_id);

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,ref_table,ref_id)
  values (b.org_id, b.item_id, b.location_id, 'production_in', b.production_date,
          v_qty, 'production_batches', b.id);

  update production_batches set status = 'closed' where id = p_batch;
end $$;
