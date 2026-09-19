-- ============================================================
-- JYOTHI FOODS ERP — 49: A DELETE THAT CAN BE SWITCHED OFF WHEN THE DATA IS IN
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- From the shop: "we want delete option in stock and this option is available
-- only to enter original data — after that we will intimate and then remove
-- that option in stock."
--
-- That is exactly right, and it must not need a new build to honour. While the
-- opening figures are being typed, a wrong stock row has to be removable. Once
-- the shop is running on real numbers, a deletable stock ledger is how a day's
-- takings quietly disappear, and nobody can tell afterwards whether the figure
-- was wrong or somebody made it wrong.
--
-- So it becomes a WINDOW the owner controls, not a permission and not a
-- release:
--
--   orgs.stock_delete_until   null  → off. A stock row cannot be deleted.
--                             date  → on until the end of that day.
--
-- It carries a date rather than a tick box on purpose. A tick box stays ticked:
-- the shop intends to tell us, the week gets busy, and the ledger is still open
-- at the next stock take. A date closes by itself and says on the screen when.
-- The owner can still stop it the moment they mean to, or push it out — both
-- are one press in Setup → Business.
--
-- Existing organisations get 30 days from today, because they are typing their
-- opening figures right now and must not be locked out by this file landing.
--
-- Also here, because it is the same ask carried on: "if it is possible add
-- delete option every where." The last two screens that had none —
--
--   Production batches  an open one simply goes; a closed one gives back the
--                       raw material and takes the boxes off the shelf
--   Recipes             one no batch has ever been made from
--
-- Both functions are restated whole, additions and all, because
-- `create or replace` keeps the last body that ran.
-- ============================================================

-- The opening 30 days are given ONLY when the column is new. "where
-- stock_delete_until is null" would have looked equivalent and been a trapdoor:
-- closed is stored as null, so re-running this file would have silently
-- re-opened a window the owner had deliberately shut.
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'orgs'
                    and column_name = 'stock_delete_until')
  then
    -- The DEFAULT matters as much as the backfill: a shop created next year is
    -- also about to type its opening figures, and would otherwise start with
    -- the ledger already sealed and no way in until somebody noticed.
    alter table orgs add column stock_delete_until date default (current_date + 30);
    update orgs set stock_delete_until = current_date + 30;
  end if;
end $$;

comment on column orgs.stock_delete_until is
  'While set and not past, a stock movement typed or imported by hand can be deleted. Null means no.';

/** Is the stock ledger open for corrections right now? */
create or replace function stock_delete_open(p_org uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select o.stock_delete_until >= current_date
                     from orgs o where o.id = coalesce(p_org, my_org_id())), false);
$$;

/**
 * Open the window for so many days, or close it now with null.
 *
 * Owner only. Deleting stock is the one thing in here that can make a figure
 * wrong with nothing left to show for it, so who may switch it on is a narrower
 * question than who may use it.
 */
create or replace function set_stock_delete_window(p_days int default null)
returns date language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_until date;
begin
  if v_org is null then raise exception 'Not signed in to an organisation'; end if;
  if my_role() <> 'owner' then
    raise exception 'Only an owner can open or close stock deletion' using errcode = '42501';
  end if;
  if p_days is null then
    v_until := null;                                   -- stop now
  elsif p_days < 1 or p_days > 90 then
    raise exception 'Give between 1 and 90 days, or nothing at all to stop it now';
  else
    v_until := current_date + p_days;
  end if;
  update orgs set stock_delete_until = v_until where id = v_org;
  return v_until;
end $$;

revoke execute on function set_stock_delete_window(int) from public, anon;
grant  execute on function set_stock_delete_window(int) to authenticated;
grant  execute on function stock_delete_open(uuid) to authenticated;


-- ── the stock row itself, now inside the window ─────────────────────────────
create or replace function delete_stock_row(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_org  uuid := my_org_id();
  r      stock_ledger%rowtype;
  v_what text;
  v_ref  text;
begin
  if v_org is null then raise exception 'Not signed in to an organisation'; end if;
  if not can_delete('stock') then
    raise exception 'Your role cannot delete stock movements' using errcode = '42501';
  end if;

  -- The window. Checked before anything else is read, so the refusal is about
  -- the setting rather than about this particular row.
  if not stock_delete_open(v_org) then
    raise exception 'Stock movements can no longer be deleted. This was open while the opening figures were being entered and has since been closed. An owner can open it again in Setup → Business.'
      using errcode = '42501';
  end if;

  select * into r from stock_ledger where id = p_id and org_id = v_org;
  if not found then raise exception 'That stock movement is not there any more'; end if;

  -- Anything carrying a document reference belongs to that document. 'import' is
  -- the one ref_table that is not a document — it is how a spreadsheet signs its
  -- rows — and null is a row somebody posted by hand.
  if r.ref_table is not null and r.ref_table <> 'import' then
    v_what := case r.ref_table
      when 'invoices'           then 'sale bill'
      when 'purchases'          then 'purchase'
      when 'sales_returns'      then 'sales return'
      when 'purchase_returns'   then 'purchase return'
      when 'delivery_challans'  then 'delivery challan'
      when 'production_batches' then 'production batch'
      when 'stock_counts'       then 'stock count'
      when 'stock_transfers'    then 'godown transfer'
      when 'vehicle_trips'      then 'van trip'
      else replace(r.ref_table, '_', ' ') end;

    v_ref := case r.ref_table
      when 'invoices'           then (select invoice_no from invoices where id = r.ref_id)
      when 'purchases'          then (select coalesce(bill_no, '') from purchases where id = r.ref_id)
      when 'sales_returns'      then (select return_no from sales_returns where id = r.ref_id)
      when 'production_batches' then (select batch_no from production_batches where id = r.ref_id)
      else null end;

    raise exception 'This movement came from a % %— delete or cancel that instead, and the stock goes back on its own.',
      v_what, coalesce(nullif(v_ref, '') || ' ', '')
      using errcode = '23503';
  end if;

  delete from stock_ledger where id = p_id and org_id = v_org;
  return 'deleted';
end $$;

revoke execute on function delete_stock_row(bigint) from public, anon;
grant  execute on function delete_stock_row(bigint) to authenticated;


create or replace function delete_master(p_kind text, p_id uuid)
returns text language plpgsql set search_path = public as $$
declare
  refs text[][];
  r text[];
  n bigint;
  v_name text;
  v_module text;
begin
  v_module := case p_kind
    when 'item' then 'items' when 'customer' then 'customers'
    when 'supplier' then 'purchases' when 'staff' then 'setup'
    when 'vehicle' then 'vehicles' when 'recipe' then 'production'
    else null end;
  if v_module is null then raise exception 'Unknown record type %', p_kind; end if;
  if not can_delete(v_module) then
    raise exception 'Your role cannot delete this' using errcode = '42501';
  end if;

  -- Everything that would be left pointing at nothing. CASCADE relationships
  -- (barcodes, price-list rows, a customer's own rate overrides) are absent on
  -- purpose: they exist only to serve this record and go with it.
  refs := case p_kind
    when 'item' then array[
      ['stock_ledger','item_id','stock movement'], ['invoice_items','item_id','sale bill'],
      ['quotation_items','item_id','quotation'], ['order_items','item_id','order'],
      ['challan_items','item_id','challan'], ['purchase_items','item_id','purchase'],
      ['purchase_return_items','item_id','purchase return'], ['sales_return_items','item_id','sales return'],
      ['stock_count_items','item_id','stock count'], ['stock_transfer_items','item_id','transfer'],
      ['batch_ingredients','ingredient_id','production batch'], ['recipe_ingredients','ingredient_id','recipe'],
      ['production_batches','item_id','production batch'], ['discount_schemes','item_id','discount scheme']]
    when 'customer' then array[
      ['invoices','customer_id','bill'], ['receipts','customer_id','receipt'],
      ['quotations','customer_id','quotation'], ['orders','customer_id','order'],
      ['delivery_challans','customer_id','challan'], ['sales_returns','customer_id','return'],
      ['cheques','customer_id','cheque'], ['inbound_orders','customer_id','WhatsApp order'],
      ['message_log','customer_id','message']]
    when 'supplier' then array[
      ['purchases','supplier_id','purchase'], ['purchase_returns','supplier_id','purchase return'],
      ['payments','supplier_id','payment'], ['orders','supplier_id','purchase order'],
      ['cheques','supplier_id','cheque']]
    when 'recipe' then array[
      ['production_batches','recipe_id','production batch']]
    when 'vehicle' then array[
      ['vehicle_trips','vehicle_id','trip'], ['invoices','vehicle_id','bill'],
      ['delivery_challans','vehicle_id','challan'], ['receipts','vehicle_id','receipt']]
    else array[
      ['invoices','created_by','bill'], ['receipts','created_by','receipt'],
      ['payments','created_by','payment'], ['purchases','created_by','purchase'],
      ['quotations','created_by','quotation'], ['orders','created_by','order'],
      ['delivery_challans','created_by','challan'], ['sales_returns','created_by','return'],
      ['purchase_returns','created_by','purchase return'], ['production_batches','chief_id','production batch'],
      ['sections','mestri_id','section'], ['vehicles','driver_id','vehicle'],
      ['vehicle_trips','driver_id','trip'], ['customers','sales_exec_id','customer'],
      ['stock_transfers','created_by','transfer'], ['stock_counts','created_by','stock count'],
      ['journal_entries','created_by','ledger entry']]
    end;

  foreach r slice 1 in array refs loop
    n := ref_count(r[1], r[2], p_id);
    if n > 0 then
      raise exception '% cannot be deleted: it is already on % %. Set it inactive instead — it then disappears from new work and every old record still reads correctly.',
        initcap(replace(p_kind, '_', ' ')), n, r[3] || case when n = 1 then '' else 's' end
        using errcode = '23503';
    end if;
  end loop;

  -- A party's own ledger account goes with them, unless it has been posted to.
  if p_kind in ('customer', 'supplier') then
    if exists (
      select 1 from ledger_accounts la join journal_lines jl on jl.account_id = la.id
       where (p_kind = 'customer' and la.customer_id = p_id) or (p_kind = 'supplier' and la.supplier_id = p_id))
    then
      raise exception 'There are ledger entries against this %. Set it inactive instead.', p_kind
        using errcode = '23503';
    end if;
    delete from ledger_accounts where (p_kind = 'customer' and customer_id = p_id) or (p_kind = 'supplier' and supplier_id = p_id);
  end if;

  case p_kind
    when 'item' then delete from items where id = p_id and org_id = my_org_id() returning name into v_name;
    when 'customer' then delete from customers where id = p_id and org_id = my_org_id() returning name into v_name;
    when 'supplier' then delete from suppliers where id = p_id and org_id = my_org_id() returning name into v_name;
    when 'vehicle' then delete from vehicles where id = p_id and org_id = my_org_id() returning vehicle_number into v_name;
    -- Ingredients cascade: they describe this recipe and nothing else.
    when 'recipe' then delete from recipes r where r.id = p_id and r.org_id = my_org_id()
      returning (select i.name from items i where i.id = r.item_id) into v_name;
    else delete from staff where id = p_id and org_id = my_org_id() returning full_name into v_name;
  end case;
  if v_name is null then raise exception 'Not found'; end if;
  return 'deleted';
end $$;

create or replace function delete_document(p_kind text, p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := my_org_id();
  v_short text; v_no text; v_module text; v_state text; v_ref text; v_other text;
  v_manual boolean; n bigint;
begin
  v_module := case p_kind
    when 'invoice' then 'invoices' when 'quotation' then 'invoices'
    when 'order' then 'invoices' when 'challan' then 'invoices'
    when 'receipt' then 'receipts' when 'payment' then 'payments'
    when 'purchase' then 'purchases' when 'purchase_return' then 'purchases'
    when 'return' then 'returns'
    when 'stock_transfer' then 'stock' when 'stock_count' then 'stock'
    when 'trip' then 'vehicles'
    when 'journal' then 'payments' when 'cheque' then 'payments'
    when 'batch' then 'production'
    else null end;
  if v_module is null then raise exception 'Unknown document type %', p_kind; end if;
  if not can_delete(v_module) then
    raise exception 'Your role cannot delete this' using errcode = '42501';
  end if;

  -- Where a cancelled state already exists, it wins: a cancelled bill that
  -- stays on the list is more honest than one that disappears.
  if p_kind = 'invoice' then perform set_invoice_status(p_id, 'cancelled'); return 'cancelled'; end if;
  if p_kind = 'order' then perform cancel_order(p_id); return 'cancelled'; end if;
  if p_kind = 'challan' then perform cancel_challan(p_id); return 'cancelled'; end if;

  if p_kind = 'quotation' then
    select quote_no into v_no from quotations where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Quotation not found'; end if;
    if exists (select 1 from quotations where id = p_id and invoice_id is not null) then
      raise exception 'Quotation % has already become a bill. Cancel that bill instead.', v_no
        using errcode = '23503';
    end if;
    delete from quotations where id = p_id and org_id = v_org;      -- lines cascade; it posted nothing
    return 'deleted';
  end if;

  if p_kind = 'receipt' then
    select receipt_no into v_no from receipts where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Receipt not found'; end if;
    if exists (select 1 from receipts where reversal_of = p_id) then
      raise exception 'Receipt % has already been reversed.', v_no using errcode = '23503';
    end if;
    perform reverse_journal(v_org, 'receipts', p_id, current_date, format('Receipt %s deleted', v_no));
    delete from receipts where id = p_id and org_id = v_org;        -- lines and allocations cascade
    return 'deleted';
  end if;

  if p_kind = 'payment' then
    select payment_no into v_no from payments where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Payment not found'; end if;
    if exists (select 1 from payments where reversal_of = p_id) then
      raise exception 'Payment % has already been reversed.', v_no using errcode = '23503';
    end if;
    perform reverse_journal(v_org, 'payments', p_id, current_date, format('Payment %s deleted', v_no));
    delete from payments where id = p_id and org_id = v_org;
    return 'deleted';
  end if;



  -- ── a production batch ──
  -- An open batch has made nothing yet and simply goes. A closed one consumed
  -- raw material and put finished boxes on the shelf, so both halves come back:
  -- the ingredients return to the godown and the boxes come off it.
  --
  -- The batch also created an item batch — the expiry-dated lot the boxes were
  -- booked into. If anything OTHER than this batch has moved against that lot,
  -- the goods have already been sold or transferred under their batch number
  -- and unwinding the production would leave those movements pointing at a lot
  -- that never existed.
  if p_kind = 'batch' then
    select batch_no, status into v_no, v_state from production_batches where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Batch not found'; end if;

    if exists (
      select 1 from stock_ledger sl
        join item_batches ib on ib.id = sl.batch_id
       where ib.production_batch_id = p_id
         and (sl.ref_table is distinct from 'production_batches' or sl.ref_id is distinct from p_id))
    then
      raise exception 'Goods made on batch % have already gone out under that batch number. Cancel or delete those documents first.', v_no
        using errcode = '23503';
    end if;

    v_short := doc_stock_shortfall('production_batches', p_id);
    if v_short is not null then
      raise exception 'Undoing batch % would leave less than nothing of "%" — what it made has already been sold.', v_no, v_short
        using errcode = '23514';
    end if;

    delete from stock_ledger where ref_table = 'production_batches' and ref_id = p_id and org_id = v_org;
    delete from item_batches where production_batch_id = p_id and org_id = v_org;
    delete from production_batches where id = p_id and org_id = v_org;   -- ingredients cascade
    return 'deleted';
  end if;

  -- ── a godown transfer ──
  -- Both halves of it go: the row that took the goods out of one godown and the
  -- row that put them into the other. Taking them back can leave the receiving
  -- godown short, if they have since been sold from there, so it is checked the
  -- same way a purchase is.
  if p_kind = 'stock_transfer' then
    select transfer_no into v_no from stock_transfers where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Transfer not found'; end if;
    v_short := doc_stock_shortfall('stock_transfers', p_id);
    if v_short is not null then
      raise exception 'The goods moved on transfer % have already been sold from where they went — undoing it would leave less than nothing of "%".', v_no, v_short
        using errcode = '23514';
    end if;
    delete from stock_ledger where ref_table = 'stock_transfers' and ref_id = p_id and org_id = v_org;
    delete from stock_transfers where id = p_id and org_id = v_org;  -- lines cascade
    return 'deleted';
  end if;

  -- ── a stock count ──
  -- A count that was never posted moved nothing and simply goes. A posted one
  -- wrote an adjustment per item, and removing those adjustments puts the book
  -- figure back to what it was before anybody counted.
  if p_kind = 'stock_count' then
    select count_no, status into v_no, v_state from stock_counts where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Stock count not found'; end if;
    if v_state = 'posted' then
      v_short := doc_stock_shortfall('stock_counts', p_id);
      if v_short is not null then
        raise exception 'Undoing count % would put "%" below nothing — the stock it added has since gone out.', v_no, v_short
          using errcode = '23514';
      end if;
      delete from stock_ledger where ref_table = 'stock_counts' and ref_id = p_id and org_id = v_org;
    end if;
    delete from stock_counts where id = p_id and org_id = v_org;     -- lines cascade
    return 'deleted';
  end if;

  -- ── a van trip ──
  -- A trip that carried bills is the record of a day's selling and must not
  -- quietly vanish from under them; those bills are cancelled first, one at a
  -- time, so each says for itself what it put back.
  if p_kind = 'trip' then
    if not exists (select 1 from vehicle_trips where id = p_id and org_id = v_org) then
      raise exception 'Trip not found';
    end if;
    select count(*) into n from invoices where trip_id = p_id and status <> 'cancelled';
    if n > 0 then
      raise exception 'This trip has % bill% on it. Cancel them first — each one has to put its goods back.',
        n, case when n = 1 then '' else 's' end using errcode = '23503';
    end if;
    select count(*) into n from receipts where trip_id = p_id;
    if n > 0 then
      raise exception 'Money was collected on this trip — % receipt% still point at it.',
        n, case when n = 1 then '' else 's' end using errcode = '23503';
    end if;
    select count(*) into n from delivery_challans where trip_id = p_id;
    if n > 0 then
      raise exception 'This trip has % challan% on it. Cancel them first.',
        n, case when n = 1 then '' else 's' end using errcode = '23503';
    end if;
    v_short := doc_stock_shortfall('vehicle_trips', p_id);
    if v_short is not null then
      raise exception 'Undoing this trip would leave less than nothing of "%".', v_short
        using errcode = '23514';
    end if;
    delete from stock_ledger where ref_table = 'vehicle_trips' and ref_id = p_id and org_id = v_org;
    update invoices set trip_id = null where trip_id = p_id and org_id = v_org;
    delete from vehicle_trips where id = p_id and org_id = v_org;
    return 'deleted';
  end if;

  -- ── a manual ledger entry ──
  -- Only a hand-written one. An entry raised by a bill or a receipt is that
  -- document's own record of itself: deleting it behind the document's back
  -- would leave the books saying one thing and the bill another, so it names
  -- the document and stops.
  if p_kind = 'journal' then
    select entry_no, is_manual, ref_table into v_no, v_manual, v_ref
      from journal_entries where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Ledger entry not found'; end if;
    if not coalesce(v_manual, false) then
      raise exception 'Entry % was raised by a %, not typed in. Delete that document and this goes with it.',
        v_no, coalesce(replace(regexp_replace(v_ref, 's$', ''), '_', ' '), 'document') using errcode = '23503';
    end if;
    -- A reversal that outlives the entry it reverses still moves the money the
    -- other way and reads as the reversal of nothing, so the pair comes apart
    -- in the order it was made.
    select entry_no into v_other from journal_entries
     where reverses_entry_id = p_id and org_id = v_org limit 1;
    if v_other is not null then
      raise exception 'Entry % has already been reversed by %. Delete that reversal first.', v_no, v_other
        using errcode = '23503';
    end if;
    -- A line on Cash or Bank moved real money through the day book. Leaving
    -- that behind would take the entry off the ledger and leave the cash book
    -- still holding it.
    delete from account_transactions where ref_table = 'journal_entries' and ref_id = p_id and org_id = v_org;
    update journal_entries e set reversed_by = null
     where e.reversed_by = p_id and e.org_id = v_org;
    delete from journal_entries where id = p_id and org_id = v_org;  -- lines cascade
    return 'deleted';
  end if;

  -- ── a cheque ──
  -- One written onto a receipt or a payment belongs to that document. A
  -- cleared or bounced one has already moved money in the bank book, so the
  -- bank entry and the ledger entry come back out with it.
  if p_kind = 'cheque' then
    select cheque_no, state, ref_table into v_no, v_state, v_ref
      from cheques where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Cheque not found'; end if;
    if v_ref is not null then
      raise exception 'Cheque % was taken on a %. Delete that instead and the cheque goes with it.',
        v_no, replace(regexp_replace(v_ref, 's$', ''), '_', ' ') using errcode = '23503';
    end if;
    delete from account_transactions where ref_table = 'cheques' and ref_id = p_id and org_id = v_org;
    perform reverse_journal(v_org, 'cheques', p_id, current_date, format('Cheque %s deleted', v_no));
    delete from cheques where id = p_id and org_id = v_org;
    return 'deleted';
  end if;

  -- The three that moved stock. Same shape: refuse if something downstream
  -- needs them, then take the stock and the ledger back before removing the row.
  if p_kind = 'purchase' then
    select bill_no into v_no from purchases where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Purchase not found'; end if;
    select count(*) into n from purchase_returns where purchase_id = p_id;
    if n > 0 then
      raise exception 'Purchase % has a return against it. Delete the return first.', v_no
        using errcode = '23503';
    end if;
    v_short := doc_stock_shortfall('purchases', p_id);
    if v_short is not null then
      raise exception 'These goods have already gone out — deleting purchase % would leave less than nothing of "%". Reverse the bills that used it first.', v_no, v_short
        using errcode = '23514';
    end if;
    delete from stock_ledger where ref_table = 'purchases' and ref_id = p_id and org_id = v_org;
    perform reverse_journal(v_org, 'purchases', p_id, current_date, format('Purchase %s deleted', v_no));
    delete from purchases where id = p_id and org_id = v_org;
    return 'deleted';
  end if;

  if p_kind = 'return' then
    select return_no into v_no from sales_returns where id = p_id and org_id = v_org;
    if v_no is null then raise exception 'Return not found'; end if;
    v_short := doc_stock_shortfall('sales_returns', p_id);
    if v_short is not null then
      raise exception 'The goods that came back on % have already gone out again — deleting it would leave less than nothing of "%".', v_no, v_short
        using errcode = '23514';
    end if;
    delete from stock_ledger where ref_table = 'sales_returns' and ref_id = p_id and org_id = v_org;
    perform reverse_journal(v_org, 'sales_returns', p_id, current_date, format('Return %s deleted', v_no));
    delete from sales_returns where id = p_id and org_id = v_org;
    return 'deleted';
  end if;

  select return_no into v_no from purchase_returns where id = p_id and org_id = v_org;
  if v_no is null then raise exception 'Purchase return not found'; end if;
  v_short := doc_stock_shortfall('purchase_returns', p_id);
  if v_short is not null then
    raise exception 'Deleting purchase return % would put the stock of "%" back below nothing.', v_no, v_short
      using errcode = '23514';
  end if;
  delete from stock_ledger where ref_table = 'purchase_returns' and ref_id = p_id and org_id = v_org;
  perform reverse_journal(v_org, 'purchase_returns', p_id, current_date, format('Purchase return %s deleted', v_no));
  delete from purchase_returns where id = p_id and org_id = v_org;
  return 'deleted';
end $$;
