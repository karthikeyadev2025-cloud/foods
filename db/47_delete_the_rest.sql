-- ============================================================
-- JYOTHI FOODS ERP — 47: A DELETE ON EVERY SCREEN THAT WAS MISSING ONE
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "If possible give delete option every where in portal." 36 did the records
-- and the documents people delete most; six screens were left with no way to
-- take anything off them at all, and a row typed by mistake stayed forever:
--
--   Vehicles          a van entered twice
--   Van trips         a trip raised for the wrong day
--   Godown transfers  stock moved to the wrong godown
--   Stock counts      a count sheet opened by accident, or posted wrong
--   Ledger entries    a hand-typed journal with the figures the wrong way round
--   Cheques           a cheque number keyed in wrong
--
-- None of them can be a plain DELETE. Every one of these has either moved
-- stock, moved money, or is being pointed at by something that would be left
-- hanging, and the row itself does not know that. So each goes the same way as
-- 36: say what is in the way in words the shop uses, or take the stock and the
-- ledger back BEFORE removing the row.
--
-- Both functions are restated whole, additions and all, because
-- `create or replace` keeps the last body that ran — there is no way to add a
-- branch to half a function.
-- ============================================================

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
    when 'vehicle' then 'vehicles'
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
