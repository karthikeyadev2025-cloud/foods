-- ============================================================
-- JYOTHI FOODS ERP — 34: SEARCH A BILL BY ANY DETAIL ON IT
--
-- 33 searched three fields: document number, party name, town. That covers the
-- office asking "number 41", and nothing else people actually reach for:
--
--   a phone number     the customer rings, the screen shows their number, and
--                      searching it found nothing
--   an amount          "the fifteen thousand receipt"
--   an item            "which bills had MYSOOR PAK last week"
--   a vehicle or LR    tracing a load that went out on AP07 TZ 1234
--   a cheque number    the bank statement has a number and nothing else
--   a note             whatever the clerk wrote at the time
--
-- So the haystack now carries everything on the document that a person could
-- reasonably remember, the lines included.
--
-- THE SHAPE OF THE CONDITION, because it is not the obvious one:
--
--   not exists (select 1 from unnest(words) w
--               where haystack not ilike w and not exists (line matches w))
--
-- read as "no word fails to match". Every word must land somewhere — the
-- document's own fields OR one of its lines — but different words may land in
-- different places, so "kaju 41" finds bill 41 that had kaju on it.
--
-- Written this way rather than aggregating each document's lines into one
-- string and matching that, which is the tidier-looking version: aggregating
-- builds the line text for every document in the table on every keystroke,
-- while this only looks at the lines for words the document's own fields did
-- not already answer, and stops at the first word that fails.
--
-- Still not security definer, for the reason 33 gives: the v_*_list views are
-- security_invoker and RLS decides what a caller may see. The line subqueries
-- read *_items and items directly, which are under the same org RLS.
--
-- FORWARD ONLY. Never run a lower-numbered file after this one.
-- ============================================================

create or replace function search_documents(p_term text, p_limit int default 20)
returns table (
  kind text,
  doc_id uuid,
  doc_no text,
  doc_date date,
  party text,
  town text,
  amount numeric,
  state text)
language plpgsql stable set search_path = public as $$
declare
  v_words text[];
  v_docs boolean := has_feature('documents');
begin
  v_words := array(
    select '%' || w || '%'
      from unnest(regexp_split_to_array(coalesce(trim(p_term), ''), '\s+')) w
     where w <> ''
     limit 6);
  if array_length(v_words, 1) is null then return; end if;

  return query
  with hits as (
    -- ---- sales invoices -------------------------------------------------
    select 'invoice'::text as kind, i.id, i.invoice_no::text as no, i.invoice_date as dt,
           i.customer_name::text as party, i.customer_town::text as town, i.total as amt, i.status::text as st
      from v_invoice_list i
     where can_view('invoices')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', i.invoice_no, i.customer_name, i.customer_town, i.customer_mobile,
                               i.vehicle_number, i.transport_name, i.lr_no, i.location_name,
                               i.notes, i.total::text, i.status::text) not ilike w
            and not exists (
              select 1 from invoice_items li join items it on it.id = li.item_id
               where li.invoice_id = i.id and concat_ws(' ', it.item_code, it.name) ilike w))

    -- ---- quotations -----------------------------------------------------
    union all
    select 'quotation', q.id, q.quote_no::text, q.quote_date, q.customer_name::text, q.customer_town::text, q.total, q.state::text
      from v_quotation_list q
     where v_docs and can_view('invoices')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', q.quote_no, q.customer_name, q.customer_town, q.customer_mobile,
                               q.transport_name, q.lr_no, q.notes, q.total::text, q.state::text) not ilike w
            and not exists (
              select 1 from quotation_items li join items it on it.id = li.item_id
               where li.quotation_id = q.id and concat_ws(' ', it.item_code, it.name) ilike w))

    -- ---- orders ---------------------------------------------------------
    union all
    select 'order', o.id, o.order_no::text, o.order_date, o.party_name::text, o.party_town::text, o.total, o.state::text
      from v_order_list o
      left join customers oc on oc.id = o.customer_id
     where v_docs and can_view('invoices')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', o.order_no, o.party_name, o.party_town, oc.mobile1, oc.mobile2,
                               o.notes, o.total::text, o.state::text, o.kind::text) not ilike w
            and not exists (
              select 1 from order_items li join items it on it.id = li.item_id
               where li.order_id = o.id and concat_ws(' ', it.item_code, it.name) ilike w))

    -- ---- delivery challans ----------------------------------------------
    union all
    select 'challan', c.id, c.challan_no::text, c.challan_date, c.customer_name::text, c.customer_town::text, null::numeric, c.state::text
      from v_challan_list c
      left join customers cc on cc.id = c.customer_id
     where v_docs and can_view('invoices')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', c.challan_no, c.customer_name, c.customer_town, cc.mobile1, cc.mobile2,
                               c.vehicle_number, c.location_name, c.notes, c.state::text) not ilike w
            and not exists (
              select 1 from challan_items li join items it on it.id = li.item_id
               where li.challan_id = c.id and concat_ws(' ', it.item_code, it.name) ilike w))

    -- ---- receipts -------------------------------------------------------
    union all
    select 'receipt', r.id, r.receipt_no::text, r.receipt_date, r.customer_name::text, r.customer_town::text, r.total_amount, r.modes::text
      from v_receipt_list r
      left join customers rc on rc.id = r.customer_id
     where can_view('receipts')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', r.receipt_no, r.customer_name, r.customer_town, rc.mobile1, rc.mobile2,
                               r.narration, r.total_amount::text, r.modes) not ilike w
            -- The cheque or UPI reference lives on the receipt's own lines.
            and not exists (
              select 1 from receipt_lines rl
               where rl.receipt_id = r.id and coalesce(rl.reference, '') ilike w))

    -- ---- payments -------------------------------------------------------
    union all
    select 'payment', p.id, p.payment_no::text, p.payment_date, p.party_name::text, null::text, p.amount, p.mode_code::text
      from v_payment_list p
     where can_view('payments')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', p.payment_no, p.party_name, p.supplier_name, p.staff_name, p.expense_head,
                               p.reference, p.narration, p.amount::text, p.mode_code) not ilike w)

    -- ---- purchases ------------------------------------------------------
    union all
    select 'purchase', pu.id, pu.bill_no::text, pu.bill_date, pu.supplier_name::text, null::text, pu.total, null::text
      from v_purchase_list pu
     where can_view('purchases')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', pu.bill_no, pu.supplier_name, pu.location_name, pu.notes, pu.total::text) not ilike w
            and not exists (
              select 1 from purchase_items li join items it on it.id = li.item_id
               where li.purchase_id = pu.id and concat_ws(' ', it.item_code, it.name) ilike w))

    -- ---- sales returns --------------------------------------------------
    union all
    select 'return', sr.id, sr.return_no::text, sr.return_date, sr.customer_name::text, sr.customer_town::text, sr.total, sr.kind::text
      from v_return_list sr
      left join customers sc on sc.id = sr.customer_id
     where can_view('returns')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', sr.return_no, sr.customer_name, sr.customer_town, sc.mobile1, sc.mobile2,
                               sr.invoice_no, sr.location_name, sr.notes, sr.total::text, sr.kind::text) not ilike w
            and not exists (
              select 1 from sales_return_items li join items it on it.id = li.item_id
               where li.return_id = sr.id and concat_ws(' ', it.item_code, it.name) ilike w))

    -- ---- purchase returns -----------------------------------------------
    union all
    select 'purchase_return', pr.id, pr.return_no::text, pr.return_date, pr.supplier_name::text, null::text, pr.total, null::text
      from v_purchase_return_list pr
     where can_view('purchases')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', pr.return_no, pr.supplier_name, pr.bill_no, pr.location_name,
                               pr.notes, pr.total::text) not ilike w
            and not exists (
              select 1 from purchase_return_items li join items it on it.id = li.item_id
               where li.return_id = pr.id and concat_ws(' ', it.item_code, it.name) ilike w))
  )
  select h.kind, h.id, h.no, h.dt, h.party, h.town, h.amt, h.st
    from hits h
   order by h.dt desc nulls last, h.no desc
   limit greatest(coalesce(p_limit, 20), 1);
end $$;
