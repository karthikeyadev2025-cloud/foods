-- ============================================================
-- JYOTHI FOODS ERP — 41: DELETE A STOCK MOVEMENT, BUT ONLY THE RIGHT ONES
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- The stock ledger is append-only by policy: it grants SELECT and INSERT and no
-- DELETE, so an ordinary DELETE removes nothing and cheerfully reports success.
-- That is deliberate — it is the record of what physically moved — and it is why
-- delete_document() and remove_duplicate_stock_rows() are SECURITY DEFINER. This
-- is the third controlled exception, and the last one needed.
--
-- WHAT MAY GO, AND WHAT MAY NOT
--
-- A movement posted BY A DOCUMENT is that document's to remove. Deleting the
-- stock line of an invoice would leave the bill claiming goods that never left
-- the godown, and every figure derived from it wrong with no trace of why. So
-- those are refused, and the refusal names the document: cancel or delete THAT,
-- and the stock comes back on its own.
--
-- What is left is exactly what a person needs to correct by hand: an opening
-- balance, an adjustment, and rows an import posted. Those were typed or loaded,
-- not earned by a bill, and a wrong one has to be removable.
--
-- NOT refused for making the stock negative. These rows are corrections by
-- definition — the usual reason to delete one is that it was never true — and a
-- shop that has already sold against a wrong opening figure must still be able
-- to take it out. Anything it leaves behind shows up immediately in
-- Stock > Problems, which is the right place to see it.
-- ============================================================

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
