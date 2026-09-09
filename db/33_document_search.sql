-- ============================================================
-- JYOTHI FOODS ERP — 33: FIND A BILL WITHOUT KNOWING WHICH SCREEN IT IS ON
--
-- Every document screen has its own search box, and each one searches only its
-- own kind. That is fine when you already know what you are looking for. It is
-- useless in the case that actually happens:
--
--   a customer rings and says "number 41" — is that an invoice, a challan, a
--   receipt or a quotation? The office opens four screens to find out.
--
-- So: one search across all nine kinds of document at once — invoices,
-- quotations, orders, challans, receipts, payments, purchases, sales returns
-- and purchase returns — by document number, party name or town.
--
-- Deliberately NOT security definer. Each v_*_list view is security_invoker,
-- so RLS decides which rows a caller may see, exactly as it does on the screens
-- themselves. A search that could see more than the screen it links to would be
-- a way around the permission model rather than a convenience. The can_view()
-- guards on top of that are so a role simply skips the kinds it has no business
-- with, instead of scanning them and finding nothing.
--
-- Words are ANDed and may appear in any of the three fields, so "srinivas 41"
-- finds number 41 for that customer without either word having to be a
-- contiguous match — the same rule the app's own search boxes now use.
--
-- FORWARD ONLY. Never run a lower-numbered file after this one.
-- ============================================================

/**
 * One row per matching document, newest first.
 *
 * `kind` is what the screen turns into a link; the app maps it to a route
 * rather than this function knowing about URLs.
 */
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
  v_docs boolean := has_feature('documents');   -- quotations, orders, challans: Growth and up
begin
  v_words := array(
    select '%' || w || '%'
      from unnest(regexp_split_to_array(coalesce(trim(p_term), ''), '\s+')) w
     where w <> ''
     limit 6);
  if array_length(v_words, 1) is null then return; end if;

  return query
  with hits as (
    select 'invoice'::text as kind, i.id, i.invoice_no::text as no, i.invoice_date as dt,
           i.customer_name::text as party, i.customer_town::text as town, i.total as amt, i.status::text as st
      from v_invoice_list i
     where can_view('invoices')
       and concat_ws(' ', i.invoice_no, i.customer_name, i.customer_town) ilike all (v_words)

    union all
    select 'quotation', q.id, q.quote_no::text, q.quote_date, q.customer_name::text, q.customer_town::text, q.total, q.state::text
      from v_quotation_list q
     where v_docs and can_view('invoices')
       and concat_ws(' ', q.quote_no, q.customer_name, q.customer_town) ilike all (v_words)

    union all
    select 'order', o.id, o.order_no::text, o.order_date, o.party_name::text, o.party_town::text, o.total, o.state::text
      from v_order_list o
     where v_docs and can_view('invoices')
       and concat_ws(' ', o.order_no, o.party_name, o.party_town) ilike all (v_words)

    union all
    select 'challan', c.id, c.challan_no::text, c.challan_date, c.customer_name::text, c.customer_town::text, null::numeric, c.state::text
      from v_challan_list c
     where v_docs and can_view('invoices')
       and concat_ws(' ', c.challan_no, c.customer_name, c.customer_town) ilike all (v_words)

    union all
    select 'receipt', r.id, r.receipt_no::text, r.receipt_date, r.customer_name::text, r.customer_town::text, r.total_amount, r.modes::text
      from v_receipt_list r
     where can_view('receipts')
       and concat_ws(' ', r.receipt_no, r.customer_name, r.customer_town) ilike all (v_words)

    union all
    select 'payment', p.id, p.payment_no::text, p.payment_date, p.party_name::text, null::text, p.amount, p.mode_code::text
      from v_payment_list p
     where can_view('payments')
       and concat_ws(' ', p.payment_no, p.party_name, p.expense_head) ilike all (v_words)

    union all
    select 'purchase', pu.id, pu.bill_no::text, pu.bill_date, pu.supplier_name::text, null::text, pu.total, null::text
      from v_purchase_list pu
     where can_view('purchases')
       and concat_ws(' ', pu.bill_no, pu.supplier_name) ilike all (v_words)

    union all
    select 'return', sr.id, sr.return_no::text, sr.return_date, sr.customer_name::text, sr.customer_town::text, sr.total, sr.kind::text
      from v_return_list sr
     where can_view('returns')
       and concat_ws(' ', sr.return_no, sr.customer_name, sr.customer_town, sr.invoice_no) ilike all (v_words)

    union all
    select 'purchase_return', pr.id, pr.return_no::text, pr.return_date, pr.supplier_name::text, null::text, pr.total, null::text
      from v_purchase_return_list pr
     where can_view('purchases')
       and concat_ws(' ', pr.return_no, pr.supplier_name, pr.bill_no) ilike all (v_words)
  )
  select h.kind, h.id, h.no, h.dt, h.party, h.town, h.amt, h.st
    from hits h
   order by h.dt desc nulls last, h.no desc
   limit greatest(coalesce(p_limit, 20), 1);
end $$;
