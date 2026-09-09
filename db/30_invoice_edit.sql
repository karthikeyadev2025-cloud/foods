-- ============================================================
-- JYOTHI FOODS ERP — 30: EDIT A CONFIRMED SALE INVOICE
--
-- Until now a sale invoice could only be edited while it was a draft. The
-- moment it was confirmed the lines locked, and a wrong rate or a wrong box
-- count could only be dealt with by cancelling the invoice and billing again —
-- which loses the number the customer already has on their copy.
--
-- The shop bills fast and finds the mistake a minute later. They need to fix
-- the bill, not replace it.
--
-- What editing a confirmed invoice actually has to undo, because confirming
-- did all of it:
--
--   stock      the goods left the godown on a stock_ledger row per line
--   ledger     Dr Debtors / Cr Sales was posted to the journal
--   lines      t_invoice_items_guard refuses to let them move off a draft
--
-- So this does not loosen the guard — it properly reverses the posting and
-- puts the invoice back to draft, which is the state the rest of the system
-- already understands as editable. Saving and confirming again re-posts both,
-- through exactly the paths that posted them the first time. Nothing here
-- invents a second way to write stock or a journal.
--
-- What it refuses, because reversing those quietly would lose real money:
--
--   money collected   a receipt allocated against the invoice
--   goods back        a sales return raised against it
--
-- Both must be undone by hand first, deliberately, by someone who can see what
-- they are undoing. Same two guards `set_invoice_status` already applies before
-- cancelling, for the same reason.
--
-- The invoice keeps its number, and the audit trail from 17 keeps every version,
-- so an edited bill can still be explained six months later.
--
-- FORWARD ONLY. Never run a lower-numbered file after this one.
-- ============================================================

/**
 * Put a confirmed / dispatched / delivered invoice back to draft so it can be
 * corrected. Reverses the stock and the journal on the way.
 *
 * Returns the status it came from, so the screen can say what it undid.
 */
create or replace function reopen_invoice(p_invoice uuid)
returns invoice_status
language plpgsql security definer set search_path = public as $$
declare inv invoices%rowtype; v_alloc numeric; n_out int; n_back int; v_from invoice_status;
begin
  if not can_edit('invoices') then
    raise exception 'Your role cannot change invoices' using errcode = '42501';
  end if;

  select * into inv from invoices where id = p_invoice and org_id = my_org_id() for update;
  if not found then raise exception 'Invoice not found'; end if;

  if inv.status = 'draft' then return 'draft'; end if;   -- already editable, nothing to undo
  if inv.status = 'cancelled' then
    raise exception 'Invoice % is cancelled, so there is nothing to edit. Make a fresh invoice.', inv.invoice_no
      using errcode = '23514';
  end if;
  v_from := inv.status;

  select coalesce(sum(amount), 0) into v_alloc from receipt_allocations where invoice_id = p_invoice;
  if v_alloc > 0 then
    raise exception 'Invoice % has % collected against it. Undo that receipt first, then edit the bill.', inv.invoice_no, trim(to_char(v_alloc, 'FM999999990.00'))
      using errcode = '23514';
  end if;
  if exists (select 1 from sales_returns where invoice_id = p_invoice) then
    raise exception 'Invoice % has a return against it. Cancel the return first, then edit the bill.', inv.invoice_no
      using errcode = '23514';
  end if;

  -- Take the goods back into the godown, exactly as cancelling would: a mirror
  -- row per line, dated today, so the original posting stays legible as history
  -- rather than being deleted out from under the stock report.
  select count(*) filter (where qty_base < 0), count(*) filter (where qty_base > 0)
    into n_out, n_back
    from stock_ledger where ref_table = 'invoices' and ref_id = p_invoice;
  if n_out > n_back then
    insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
    select inv.org_id, ii.item_id, inv.location_id, 'sale', current_date,
           ii.qty_base, ii.rate, 'invoices', inv.id, inv.created_by
      from invoice_items ii where ii.invoice_id = p_invoice;
  end if;

  perform reverse_journal(inv.org_id, 'invoices', inv.id, current_date,
                          format('Invoice %s reopened for correction', inv.invoice_no));

  -- t_invoice_post fires on this, and post_invoice_stock does nothing for a
  -- draft — the reversal above is the whole of it. Confirming again re-posts.
  update invoices set status = 'draft' where id = p_invoice;

  return v_from;
end $$;
