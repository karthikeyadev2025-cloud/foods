-- ============================================================
-- JYOTHI FOODS ERP — 35: THE PEOPLE AND THE PRODUCTS, NOT ONLY THEIR BILLS
--
-- 33 and 34 search documents. Type a supplier's name and you get their
-- purchases; you never get the supplier. So a supplier just created shows up
-- nowhere at all until somebody buys from them, which reads exactly like the
-- record was never saved.
--
-- The search now also returns the master records themselves — customers,
-- suppliers, products and staff — and puts them ABOVE the documents, because
-- when both match a name, the record is nearly always what was wanted: it is
-- the one place that shows the phone number, the outstanding, and every bill at
-- once.
--
-- Master rows reuse the document columns rather than widening the result:
--
--   doc_no   the code — customer code, item code; blank where there is none
--   doc_date null. A master has no date, and sorting by one would be a lie.
--   party    the name
--   town     the town, or the section for a product
--   amount   what the number means for that kind: outstanding for a customer,
--            payable for a supplier, the rate for a product
--   state    the phone number, or 'inactive' for a stopped record
--
-- Ordering is by group first — masters, then documents newest first — so the
-- nulls in doc_date never decide anything.
--
-- Same permission rule as before: not security definer, and each kind is gated
-- by the can_view() its own screen uses, so nobody finds a record through the
-- search that their role could not open directly.
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
    -- ================= the records themselves (group 0) =================
    select 0 as grp, 'customer'::text as kind, c.id, coalesce(c.code, '')::text as no, null::date as dt,
           c.name::text as party, c.town::text as town, c.outstanding as amt,
           (case when not c.is_active then 'inactive' else c.mobile1 end)::text as st
      from v_customer_list c
     where can_view('customers')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', c.code, c.name, c.town, c.mobile1, c.mobile2, c.mobile3,
                               c.address, c.route_name, c.sales_exec_name) not ilike w)

    union all
    select 0, 'supplier', s.id, ''::text, null::date, s.name::text, s.town::text, s.payable,
           (case when not s.is_active then 'inactive' else s.mobile1 end)::text
      from v_supplier_list s
     where can_view('purchases')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', s.name, s.town, s.mobile1) not ilike w)

    union all
    select 0, 'item', i.id, i.item_code::text, null::date, i.name::text, i.section_name::text, i.unit_rate,
           case when i.is_active then i.pack_code else 'inactive' end::text
      from v_item_list i
     where can_view('items')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', i.item_code, i.name, i.section_name, i.pack_code, i.type::text) not ilike w)

    union all
    select 0, 'staff', st.id, ''::text, null::date, st.full_name::text, st.designation::text, st.daily_wage,
           (case when not st.is_active then 'inactive' else st.phone end)::text
      from staff st
     where can_view('setup') and st.org_id = my_org_id()
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', st.full_name, st.phone, st.role::text, st.designation) not ilike w)

    -- ================= the documents (group 1) =========================
    union all
    select 1, 'invoice', i.id, i.invoice_no::text, i.invoice_date,
           i.customer_name::text, i.customer_town::text, i.total, i.status::text
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

    union all
    select 1, 'quotation', q.id, q.quote_no::text, q.quote_date, q.customer_name::text, q.customer_town::text, q.total, q.state::text
      from v_quotation_list q
     where v_docs and can_view('invoices')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', q.quote_no, q.customer_name, q.customer_town, q.customer_mobile,
                               q.transport_name, q.lr_no, q.notes, q.total::text, q.state::text) not ilike w
            and not exists (
              select 1 from quotation_items li join items it on it.id = li.item_id
               where li.quotation_id = q.id and concat_ws(' ', it.item_code, it.name) ilike w))

    union all
    select 1, 'order', o.id, o.order_no::text, o.order_date, o.party_name::text, o.party_town::text, o.total, o.state::text
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

    union all
    select 1, 'challan', c.id, c.challan_no::text, c.challan_date, c.customer_name::text, c.customer_town::text, null::numeric, c.state::text
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

    union all
    select 1, 'receipt', r.id, r.receipt_no::text, r.receipt_date, r.customer_name::text, r.customer_town::text, r.total_amount, r.modes::text
      from v_receipt_list r
      left join customers rc on rc.id = r.customer_id
     where can_view('receipts')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', r.receipt_no, r.customer_name, r.customer_town, rc.mobile1, rc.mobile2,
                               r.narration, r.total_amount::text, r.modes) not ilike w
            and not exists (
              select 1 from receipt_lines rl
               where rl.receipt_id = r.id and coalesce(rl.reference, '') ilike w))

    union all
    select 1, 'payment', p.id, p.payment_no::text, p.payment_date, p.party_name::text, null::text, p.amount, p.mode_code::text
      from v_payment_list p
     where can_view('payments')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', p.payment_no, p.party_name, p.supplier_name, p.staff_name, p.expense_head,
                               p.reference, p.narration, p.amount::text, p.mode_code) not ilike w)

    union all
    select 1, 'purchase', pu.id, pu.bill_no::text, pu.bill_date, pu.supplier_name::text, null::text, pu.total, null::text
      from v_purchase_list pu
     where can_view('purchases')
       and not exists (
         select 1 from unnest(v_words) w
          where concat_ws(' ', pu.bill_no, pu.supplier_name, pu.location_name, pu.notes, pu.total::text) not ilike w
            and not exists (
              select 1 from purchase_items li join items it on it.id = li.item_id
               where li.purchase_id = pu.id and concat_ws(' ', it.item_code, it.name) ilike w))

    union all
    select 1, 'return', sr.id, sr.return_no::text, sr.return_date, sr.customer_name::text, sr.customer_town::text, sr.total, sr.kind::text
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

    union all
    select 1, 'purchase_return', pr.id, pr.return_no::text, pr.return_date, pr.supplier_name::text, null::text, pr.total, null::text
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
   order by h.grp, h.dt desc nulls last, h.party, h.no desc
   limit greatest(coalesce(p_limit, 20), 1);
end $$;
