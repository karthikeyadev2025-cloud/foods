-- ============================================================
-- JYOTHI FOODS ERP — 61: A RETURN CAN BE CORRECTED
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- From the shop: "in returns they want edit option too". A return is typed at
-- the counter with the customer standing there, and the boxes, the rate or the
-- kind of return get it wrong as often as a purchase does. Until now the only
-- way out was to delete the return and type it again, which loses its number
-- and its trail.
--
-- It is corrected the same way a purchase is (db/53, db/58, db/60), and for the
-- same reasons:
--
--   * The old stock posting is REVERSED with opposite rows, never deleted.
--     stock_ledger is append-only — it has an insert policy and nothing else —
--     so a delete against it from the app silently removes no rows at all.
--     db/05 learned that the hard way and replaced post_return_stock's delete
--     with a flat refusal to post twice. That refusal stays, but it now asks
--     whether the return still HOLDS any stock rather than whether it has any
--     rows: after a reversal the rows are still there and must be, and they
--     cancel to nothing, which is precisely when posting again is right.
--
--   * The reversal is dated on the RETURN's own date, so correcting last
--     Tuesday's return does not read as goods coming back today.
--
--   * The credit is corrected by a reversing journal entry, so both the
--     original and the correction stay in the books.
--
--   * Saving a return that has not changed writes NOTHING — no reversal, no
--     reposting, no journal entry. The shop's purchase ledger had one bill
--     holding 64 postings and 63 reversals because a save ran over and over
--     (db/60); returns get that guard from the day they become editable rather
--     than after the same accident.
--
--   * A fresh return that came back into the godown and has since been sold on
--     again cannot be quietly reduced: the edit is refused by name, in words,
--     rather than leaving less than nothing on the shelf.
--
-- The return keeps its number. A return number is read out to the customer and
-- written on the slip in their hand; an edit must never draw a fresh one.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Taking a return's stock back out
-- ------------------------------------------------------------
-- One reversing row per product and godown, netted, so a return corrected five
-- times leaves five pairs rather than five times its lines. Only a FRESH return
-- moves stock; a damage return writes a zero-quantity marker and a rate
-- difference writes nothing, and `having sum(qty_base) <> 0` leaves both alone.
create or replace function unpost_return_stock(p_return uuid, p_on date default null)
returns int language plpgsql as $$
declare n int := 0;
begin
  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select org_id, item_id, location_id, 'sale_return'::stock_txn_type,
         coalesce(p_on, max(txn_date)),
         -sum(qty_base), max(rate), 'sales_returns', ref_id,
         -- created_by is a uuid and there is no max() for one — the mistake
         -- that stopped every purchase edit dead (db/59).
         coalesce(my_staff_id(), (array_agg(created_by order by id desc))[1])
    from stock_ledger
   where ref_table = 'sales_returns' and ref_id = p_return
   group by org_id, item_id, location_id, ref_id
  having sum(qty_base) <> 0;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function unpost_return_stock(uuid, date) to authenticated;

-- ------------------------------------------------------------
-- 2. Posting it, once
-- ------------------------------------------------------------
create or replace function post_return_stock(p_return uuid)
returns void language plpgsql as $$
declare r sales_returns%rowtype; v_net numeric;
begin
  select * into r from sales_returns where id = p_return;
  if not found then return; end if;
  if r.kind = 'rate_difference' or r.location_id is null then return; end if;

  -- db/05's guard against posting the same return twice, asked of what the
  -- return HOLDS rather than of how many rows it has. A return that was posted
  -- and then reversed holds nothing, and that is the one case where posting it
  -- again is the whole point.
  select coalesce(sum(qty_base), 0) into v_net
    from stock_ledger where ref_table = 'sales_returns' and ref_id = p_return;
  if v_net <> 0 then
    raise exception 'Return % is already posted to stock. Corrections are adjustment rows.', r.return_no;
  end if;

  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select r.org_id, ri.item_id, r.location_id,
         case when r.kind = 'fresh_return' then 'sale_return'::stock_txn_type
              else 'damage'::stock_txn_type end,
         r.return_date,
         case when r.kind = 'fresh_return' then ri.qty_base else 0 end,
         coalesce(ri.new_rate, ri.old_rate, 0), 'sales_returns', r.id, r.created_by
    from sales_return_items ri
   where ri.return_id = p_return
     -- A damage return's row carries no quantity; it is a marker that the
     -- breakage happened. Correcting the return must not leave a second one.
     and (r.kind = 'fresh_return'
          or not exists (select 1 from stock_ledger s
                          where s.ref_table = 'sales_returns' and s.ref_id = r.id
                            and s.item_id = ri.item_id));
end $$;

-- ------------------------------------------------------------
-- 3. save_sales_return, with an edit path
-- ------------------------------------------------------------
create or replace function save_sales_return(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; v_kind return_kind; v_loc uuid; v_inv uuid; v_cust uuid;
  l jsonb; n int := 0; it items%rowtype; v_qty numeric; v_amt numeric; v_total numeric := 0; v_rate numeric; v_new numeric;
  v_pct numeric; v_cust_name text; v_no text; v_date date;
  v_edit boolean; v_same boolean; v_old_lines text[]; v_new_lines text[];
  v_before jsonb; k text; v_item uuid; v_locn uuid; v_bal numeric; v_was numeric; v_now numeric; v_short text;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A return needs at least one line';
  end if;
  v_kind := (p_header->>'kind')::return_kind;
  v_cust := (p_header->>'customer_id')::uuid;
  v_inv  := nullif(p_header->>'invoice_id','')::uuid;
  v_loc  := nullif(p_header->>'location_id','')::uuid;
  v_date := coalesce(nullif(p_header->>'return_date','')::date, current_date);
  v_id   := nullif(p_header->>'id', '')::uuid;
  v_edit := v_id is not null;

  if v_kind = 'rate_difference' then
    v_loc := null;                                   -- never a stock movement
  elsif v_loc is null then
    raise exception 'A % needs the location the goods came back to', v_kind;
  end if;
  if v_inv is not null and not exists (select 1 from invoices where id = v_inv and customer_id = v_cust) then
    raise exception 'That invoice does not belong to this customer';
  end if;
  select breakage_recovery_pct into v_pct from orgs where id = v_org;

  if v_edit then
    select return_no into v_no from sales_returns where id = v_id and org_id = v_org;
    if v_no is null then raise exception 'Return not found'; end if;

    -- ---- nothing changed? then nothing happens (db/60's rule) ----
    select r.customer_id = v_cust
       and r.invoice_id  is not distinct from v_inv
       and r.kind        = v_kind
       and r.return_date = v_date
       and r.location_id is not distinct from v_loc
       and r.notes       is not distinct from nullif(p_header->>'notes','')
      into v_same
      from sales_returns r where r.id = v_id;

    if v_same then
      select coalesce(array_agg(sig order by sig), '{}') into v_old_lines
        from (select ri.item_id::text || '|'
                     || round(coalesce(ri.qty, 0), 3)::text || '|'
                     || round(coalesce(ri.old_rate, 0), 2)::text || '|'
                     || coalesce(round(ri.new_rate, 2)::text, '-') as sig
                from sales_return_items ri where ri.return_id = v_id) a;

      -- Built the way the line loop below builds the row, so the same return
      -- sent twice compares equal however the screen phrased it.
      select coalesce(array_agg(sig order by sig), '{}') into v_new_lines
        from (select (x->>'item_id') || '|'
                     || round(coalesce(nullif(x->>'boxes','')::numeric, 0) * i.units_per_box, 3)::text || '|'
                     || round(coalesce(nullif(x->>'rate','')::numeric, i.unit_rate, 0), 2)::text || '|'
                     || coalesce(round(nullif(x->>'new_rate','')::numeric, 2)::text, '-') as sig
                from jsonb_array_elements(p_lines) x
                left join items i on i.id = (x->>'item_id')::uuid) b;

      v_same := v_old_lines = v_new_lines;
    end if;

    -- `if null then` is false: anything that could not be compared falls
    -- through to the ordinary edit rather than being silently skipped.
    if v_same then
      return v_id;
    end if;

    select coalesce(jsonb_object_agg(key, val), '{}'::jsonb) into v_before
      from (select item_id::text || '|' || location_id::text as key, sum(qty_base) as val
              from stock_ledger
             where ref_table = 'sales_returns' and ref_id = v_id
             group by 1) s;

    perform unpost_return_stock(v_id);
    perform reverse_journal(v_org, 'sales_returns', v_id,
                            (select return_date from sales_returns where id = v_id),
                            format('Return %s corrected', v_no));

    update sales_returns set
      customer_id = v_cust,
      invoice_id  = v_inv,
      return_date = v_date,
      kind        = v_kind,
      location_id = v_loc,
      notes       = nullif(p_header->>'notes','')
    where id = v_id and org_id = v_org;

    delete from sales_return_items where return_id = v_id;
  else
    v_no := next_doc_no(v_org, 'return');
    insert into sales_returns (org_id, return_no, customer_id, invoice_id, return_date, kind, location_id, notes, created_by)
    values (v_org, v_no, v_cust, v_inv, v_date, v_kind, v_loc, nullif(p_header->>'notes',''), my_staff_id())
    returning id into v_id;
  end if;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    select * into it from items where id = (l->>'item_id')::uuid and org_id = v_org;
    if not found then raise exception 'Line %: item not found', n; end if;
    if coalesce((l->>'boxes')::numeric, 0) <= 0 then raise exception 'Line %: boxes must be greater than zero', n; end if;
    v_qty  := round((l->>'boxes')::numeric * it.units_per_box, 3);      -- boxes → units, item's own packing
    v_rate := coalesce(nullif(l->>'rate','')::numeric, it.unit_rate);
    v_new  := nullif(l->>'new_rate','')::numeric;
    v_amt := case v_kind
      when 'fresh_return'    then round(v_qty * v_rate, 2)
      when 'damage_return'   then round(v_qty * v_rate * v_pct / 100, 2)
      when 'rate_difference' then round(v_qty * (v_rate - coalesce(v_new, v_rate)), 2)
    end;
    if v_kind = 'rate_difference' and v_new is null then
      raise exception 'Line %: a rate difference needs the new rate', n;
    end if;
    insert into sales_return_items (return_id, item_id, qty, uom_id, old_rate, new_rate, amount)
    values (v_id, it.id, v_qty, it.base_uom_id, v_rate, v_new, v_amt);
    v_total := v_total + v_amt;
  end loop;

  update sales_returns set total = round(v_total, 2) where id = v_id;
  perform post_return_stock(v_id);

  -- Goods that came back and went out again cannot be un-returned. Compared
  -- before against after, so a product already standing negative for some other
  -- reason is still correctable — only the part this return is responsible for
  -- is its to answer for.
  if v_edit then
    for k in
      select key from jsonb_object_keys(v_before) as key
      union
      select item_id::text || '|' || location_id::text
        from stock_ledger where ref_table = 'sales_returns' and ref_id = v_id
    loop
      v_item := split_part(k, '|', 1)::uuid;
      v_locn := split_part(k, '|', 2)::uuid;

      select coalesce(sum(qty_base), 0) into v_bal
        from stock_ledger where item_id = v_item and location_id = v_locn;
      if v_bal >= 0 then continue; end if;

      v_was := coalesce((v_before->>k)::numeric, 0);
      select coalesce(sum(qty_base), 0) into v_now
        from stock_ledger
       where ref_table = 'sales_returns' and ref_id = v_id
         and item_id = v_item and location_id = v_locn;

      if v_bal - (v_now - v_was) >= 0 then
        select name into v_short from items where id = v_item;
        raise exception 'Return % cannot be changed this way — the goods that came back have gone out again, and it would leave less than nothing of "%". Reverse the bills that used them first.', v_no, v_short
          using errcode = '23514';
      end if;
    end loop;
  end if;

  select name into v_cust_name from customers where id = v_cust;
  perform post_journal(v_org, v_date, format('%s %s — %s', replace(v_kind::text, '_', ' '), v_no, v_cust_name), 'sales_returns', v_id,
    jsonb_build_array(
      jsonb_build_object('account', case v_kind when 'fresh_return' then 'SALES_RETURNS'
                                                 when 'damage_return' then 'BREAKAGE'
                                                 else 'RATE_DIFF' end, 'debit', round(v_total, 2)),
      jsonb_build_object('account', 'DEBTORS', 'credit', round(v_total, 2))));
  return v_id;
end $$;
