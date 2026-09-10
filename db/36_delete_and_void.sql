-- ============================================================
-- JYOTHI FOODS ERP — 36: DELETE, EVERYWHERE, WITHOUT WRECKING THE BOOKS
--
-- Almost nothing could be deleted. Suppliers and the Setup lists had a delete;
-- products, customers, quotations, receipts, payments, purchases and returns
-- had none at all, so a bill entered by mistake stayed for ever.
--
-- Two different things are being asked for by the one word "delete", and they
-- need different answers:
--
--   A RECORD (product, customer, supplier, staff)
--     Delete it outright when nothing points at it. Once it appears on even one
--     document, deleting it would leave that document naming a thing that no
--     longer exists — so it is refused, with a count of what is in the way, and
--     the screen offers Inactive instead, which hides it from new work and
--     leaves every old bill readable.
--
--   A DOCUMENT (bill, receipt, purchase, return)
--     Whatever it posted has to come back first: the stock it moved, the entry
--     it made in the ledger. Where a cancelled state already exists — invoices,
--     orders, challans — it is used, because a cancelled bill that stays
--     visible is more honest than one that vanishes. Where it does not, the
--     document is removed after its postings are reversed, and the audit trail
--     from 17 keeps who did it and when. Every one of these tables is audited.
--
-- The guard that matters most: a purchase whose goods have since been SOLD
-- cannot be deleted, because removing it would drive that item's stock
-- negative and quietly corrupt every stock figure after it. That is checked
-- per item and per location and named in the refusal.
--
-- FORWARD ONLY. Never run a lower-numbered file after this one.
-- ============================================================

-- ------------------------------------------------------------
-- 1. How many rows point at this one
-- ------------------------------------------------------------
/**
 * Counting references one table at a time, by name, because the alternative is
 * forty near-identical exists() clauses that nobody will keep in step with the
 * schema. Runs as the caller, so RLS still applies.
 */
create or replace function ref_count(p_table text, p_col text, p_id uuid)
returns bigint language plpgsql stable as $$
declare n bigint;
begin
  execute format('select count(*) from public.%I where %I = $1', p_table, p_col) into n using p_id;
  return n;
end $$;

-- ------------------------------------------------------------
-- 2. Would removing this document's stock leave someone short?
-- ------------------------------------------------------------
/**
 * The name of the first item that would go negative somewhere if this
 * document's stock rows were taken away, or null when nothing would.
 *
 * This is what stops a purchase being deleted after its goods have been sold:
 * the stock came in, went out on a bill, and removing the inbound half would
 * leave the shop showing less than nothing.
 */
create or replace function doc_stock_shortfall(p_ref_table text, p_ref_id uuid)
returns text language plpgsql stable set search_path = public as $$
declare v_name text;
begin
  select i.name into v_name
    from (select item_id, location_id, sum(qty_base) as moved
            from stock_ledger
           where ref_table = p_ref_table and ref_id = p_ref_id
           group by 1, 2) d
    join items i on i.id = d.item_id
   where d.moved <> 0
     and coalesce((select sum(sl.qty_base) from stock_ledger sl
                    where sl.item_id = d.item_id and sl.location_id = d.location_id), 0) - d.moved < 0
   limit 1;
  return v_name;
end $$;

-- ------------------------------------------------------------
-- 3. Deleting a record
-- ------------------------------------------------------------
/**
 * Delete a product, customer, supplier or member of staff, or explain what is
 * standing in the way. Returns 'deleted'.
 */
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
    else delete from staff where id = p_id and org_id = my_org_id() returning full_name into v_name;
  end case;
  if v_name is null then raise exception 'Not found'; end if;
  return 'deleted';
end $$;

-- ------------------------------------------------------------
-- 4. Deleting or cancelling a document
-- ------------------------------------------------------------
/**
 * Undo a document. Returns 'cancelled' when the record stays on screen marked
 * cancelled, 'deleted' when it is removed. Reverses stock and ledger either way.
 */
/**
 * SECURITY DEFINER for one reason: the stock ledger is append-only by policy —
 * it grants SELECT and INSERT and no DELETE — so an ordinary caller's delete
 * removes nothing and reports success, which is how the first version of this
 * silently left a deleted purchase's stock behind.
 *
 * That policy is worth keeping, so this function is the single controlled way
 * past it rather than the policy being loosened for everyone. It pays for the
 * privilege: can_delete() is checked first, every statement is scoped to
 * my_org_id(), and no id reaches a query without the org test alongside it.
 */
create or replace function delete_document(p_kind text, p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_short text; v_no text; v_module text; n bigint;
begin
  v_module := case p_kind
    when 'invoice' then 'invoices' when 'quotation' then 'invoices'
    when 'order' then 'invoices' when 'challan' then 'invoices'
    when 'receipt' then 'receipts' when 'payment' then 'payments'
    when 'purchase' then 'purchases' when 'purchase_return' then 'purchases'
    when 'return' then 'returns' else null end;
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
