-- ============================================================
-- JYOTHI FOODS ERP — 62: CORRECTING A BILL MADE EVERY EARLIER DAY WRONG
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- From the shop: "stock check now lot of minus opening why". Here is why,
-- reproduced on a clean database — 100 boxes in the godown, a bill for 10 on
-- the 8th, nothing else:
--
--   stock as at the 11th, before anybody touched it ......... 90 boxes
--   the same bill corrected on the 14th, to the SAME figures
--   stock as at the 11th, asked again ....................... 80 boxes
--   stock as at the 14th .................................... 90 boxes
--
-- The bill went out once and was counted twice, on every day between the bill
-- and the correction. Today always came out right, which is why this went
-- unseen while the opening column — yesterday's closing — filled up with minus.
--
-- The cause is two dates that should have been one. Selling posts the goods out
-- on the BILL's date; giving them back, when a bill is reopened for correction
-- or cancelled, posted them back in on TODAY's date:
--
--   08-10   -320   the bill
--   14-10   +320   reopened for correction          <- today
--   08-10   -320   the corrected bill
--
-- Between the 8th and the 14th the ledger holds -640 for a bill of -320. The
-- same split was in the money: the sale is posted on the bill's date and the
-- reversal was posted today, so a sales figure for any past day double-counted
-- every bill corrected after it.
--
-- db/58 fixed exactly this for purchases. This is the sales side of it: a
-- correction, and a cancellation, now sit on the BILL's own date, so they land
-- against the posting they are undoing and cancel it everywhere, not just from
-- today onwards. A bill corrected to the same figures becomes what it always
-- should have been — no change on any date at all.
--
-- A cancelled bill likewise stops leaving a week-long dent in the stock. The
-- goods never left: the bill is void, and it is now void from its own date
-- rather than from the day somebody got round to cancelling it.
--
-- This does not repair the rows already written. The pairs that are already
-- split across two dates stay split — they are history, and they cancel out by
-- today. db/why_minus.sql section 9 names every document that has them, so the
-- shop can see which of its past days are affected and by how much.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Giving the goods back, on the day they went out
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
      -- On the BILL's date, not today (db/62). A cancelled bill is a bill that
      -- never happened, and it has to stop having happened on the day it was
      -- for — otherwise every stock report in between shows goods gone that
      -- are standing on the shelf.
      insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
      select inv.org_id, ii.item_id, inv.location_id, 'sale', inv.invoice_date,
             ii.qty_base, ii.rate, 'invoices', inv.id, inv.created_by
      from invoice_items ii where ii.invoice_id = p_invoice;
    end if;
  end if;
end $$;

-- ------------------------------------------------------------
-- 2. Reopening a bill for correction
-- ------------------------------------------------------------
create or replace function reopen_invoice(p_invoice uuid)
returns invoice_status language plpgsql as $$
declare inv invoices%rowtype; v_from invoice_status; n_out int; n_back int; v_alloc numeric;
begin
  select * into inv from invoices where id = p_invoice and org_id = my_org_id();
  if not found then raise exception 'Invoice not found'; end if;
  if not can_edit('invoices') then
    raise exception 'Your role cannot change invoices' using errcode = '42501';
  end if;
  v_from := inv.status;
  if inv.status = 'draft' then return v_from; end if;
  if inv.status = 'cancelled' then
    raise exception 'Invoice % is cancelled; it cannot be edited.', inv.invoice_no using errcode = '23514';
  end if;

  select coalesce(sum(amount), 0) into v_alloc from receipt_allocations where invoice_id = p_invoice;
  if v_alloc > 0 then
    raise exception 'Invoice % has % allocated against it from receipts. Reverse the receipt first, then edit the bill.', inv.invoice_no, v_alloc
      using errcode = '23514';
  end if;
  if exists (select 1 from sales_returns where invoice_id = p_invoice) then
    raise exception 'Invoice % has a return against it. Cancel the return first, then edit the bill.', inv.invoice_no
      using errcode = '23514';
  end if;

  -- Take the goods back into the godown: a mirror row per line, on the BILL's
  -- own date (db/62), so the original posting stays legible as history and the
  -- pair cancels on the day the goods went out rather than only from today.
  -- Dated today, a bill corrected a week later was counted twice for that whole
  -- week, which is what filled the stock report's opening column with minus.
  select count(*) filter (where qty_base < 0), count(*) filter (where qty_base > 0)
    into n_out, n_back
    from stock_ledger where ref_table = 'invoices' and ref_id = p_invoice;
  if n_out > n_back then
    insert into stock_ledger (org_id, item_id, location_id, txn_type, txn_date, qty_base, rate, ref_table, ref_id, created_by)
    select inv.org_id, ii.item_id, inv.location_id, 'sale', inv.invoice_date,
           ii.qty_base, ii.rate, 'invoices', inv.id, inv.created_by
      from invoice_items ii where ii.invoice_id = p_invoice;
  end if;

  -- and the money the same way: posted on the bill's date, so reversed there
  perform reverse_journal(inv.org_id, 'invoices', inv.id, inv.invoice_date,
                          format('Invoice %s reopened for correction', inv.invoice_no));

  -- t_invoice_post fires on this, and post_invoice_stock does nothing for a
  -- draft — the reversal above is the whole of it. Confirming again re-posts.
  update invoices set status = 'draft' where id = p_invoice;

  return v_from;
end $$;

-- ------------------------------------------------------------
-- 3. Cancelling a bill
-- ------------------------------------------------------------
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
    -- On the bill's own date (db/62): the sale was posted there, so a sales
    -- figure for that day must stop counting it.
    perform reverse_journal(inv.org_id, 'invoices', inv.id, inv.invoice_date, format('Cancelled invoice %s', inv.invoice_no));
  end if;
end $$;
