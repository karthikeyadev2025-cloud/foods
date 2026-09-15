-- ============================================================
-- JYOTHI FOODS ERP — 42: REMOVE A PRODUCT OUTRIGHT, STOCK AND ALL
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- delete_master('item', …) refuses a product the moment it has a single stock
-- movement — including the opening row an import posted. That is right for a
-- product the shop has traded, and wrong for the case that actually keeps
-- happening: a product typed or imported by mistake, carrying nothing but the
-- stock row that created it. There was no way to be rid of it, so the master
-- fills up with rubbish nobody can clear.
--
-- purge_item() is that way, and it stops exactly where the money starts.
--
-- WHAT STILL REFUSES
-- Every document: a sale bill, quotation, order, challan, purchase, either kind
-- of return, a stock count, a godown transfer, a production batch, a recipe, a
-- discount scheme. If a product appears on any of them it is part of the
-- shop's history and must not vanish — the refusal names what is holding it,
-- and Set inactive is still there.
--
-- WHAT GOES
-- The product, and the stock movements nobody billed: openings, adjustments,
-- and rows an import signed. Those are the rows that only ever existed to
-- describe this product. Barcodes, price-list lines and customer rate overrides
-- go with it on their own — they cascade, because they exist only to serve it.
--
-- This is destructive and it is meant to be. It is also the narrowest possible
-- version of what was asked for: everything with a bill behind it is still safe.
-- ============================================================

create or replace function purge_item(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_org  uuid := my_org_id();
  refs   text[][];
  r      text[];
  n      bigint;
  v_name text;
  v_code text;
  v_rows bigint;
begin
  if v_org is null then raise exception 'Not signed in to an organisation'; end if;
  if not can_delete('items') then
    raise exception 'Your role cannot delete products' using errcode = '42501';
  end if;

  select item_code, name into v_code, v_name from items where id = p_id and org_id = v_org;
  if v_code is null then raise exception 'That product is not there any more'; end if;

  -- Everything that would be left pointing at nothing. stock_ledger is the one
  -- absentee, and the only one: it is what this function exists to clear.
  refs := array[
    ['invoice_items','item_id','sale bill'], ['quotation_items','item_id','quotation'],
    ['order_items','item_id','order'], ['challan_items','item_id','challan'],
    ['purchase_items','item_id','purchase'], ['purchase_return_items','item_id','purchase return'],
    ['sales_return_items','item_id','sales return'], ['stock_count_items','item_id','stock count'],
    ['stock_transfer_items','item_id','godown transfer'], ['batch_ingredients','ingredient_id','production batch'],
    ['recipe_ingredients','ingredient_id','recipe'], ['production_batches','item_id','production batch'],
    ['discount_schemes','item_id','discount scheme']];

  foreach r slice 1 in array refs loop
    n := ref_count(r[1], r[2], p_id);
    if n > 0 then
      raise exception '% cannot be removed: it is on % %. Set it inactive instead — it then disappears from new work and every old record still reads correctly.',
        coalesce(v_name, v_code), n, r[3] || case when n = 1 then '' else 's' end
        using errcode = '23503';
    end if;
  end loop;

  -- No document names it, so the only stock rows it can have are ones somebody
  -- typed or an import posted. Anything else would mean a document this list
  -- does not know about, and that is a reason to stop, not to guess.
  select count(*) into n from stock_ledger
   where org_id = v_org and item_id = p_id
     and ref_table is not null and ref_table <> 'import';
  if n > 0 then
    raise exception '% has % stock movement(s) posted by a document. Delete or cancel that document first.',
      coalesce(v_name, v_code), n using errcode = '23503';
  end if;

  delete from stock_ledger where org_id = v_org and item_id = p_id;
  get diagnostics v_rows = row_count;

  delete from items where id = p_id and org_id = v_org;
  if not found then raise exception 'That product is not there any more'; end if;

  return case
    when v_rows = 0 then format('%s removed', coalesce(v_name, v_code))
    else format('%s removed, with %s stock movement%s', coalesce(v_name, v_code), v_rows,
                case when v_rows = 1 then '' else 's' end)
  end;
end $$;

revoke execute on function purge_item(uuid) from public, anon;
grant  execute on function purge_item(uuid) to authenticated;
