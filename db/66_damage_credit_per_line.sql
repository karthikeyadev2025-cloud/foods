-- ============================================================
-- JYOTHI FOODS ERP — 66: THE DAMAGE CREDIT IS NOT ALWAYS HALF
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- A damage return credited the customer a fixed share of what the goods were
-- billed at — orgs.breakage_recovery_pct, 50 per cent, the same for every
-- return and every item on it. But a crushed box of biscuits and a jar with a
-- cracked lid are not the same loss, and the counter was settling the
-- difference by arguing rather than by typing it.
--
-- The percentage is now per LINE, and the shop's figure is only the default:
-- blank behaves exactly as before, so every return already entered still
-- reads the same and nothing has to be re-keyed.
--
-- Per line rather than per return because the complaint is per item — "based
-- on the condition of the damaged item" — and a return often carries several
-- in different states. A percentage rather than a typed amount because the
-- credit has to stay tied to what was billed: the screen shows the rupees as
-- the percentage is typed, so an amount can be hit exactly, and the figure
-- still explains itself on a statement six months later.
--
-- The guard that stops a return being saved over and over (db/61) compares
-- the lines, so the percentage is part of that comparison now: without it,
-- changing only the percentage would have been read as "nothing changed" and
-- silently done nothing at all.
-- ============================================================

alter table sales_return_items
  add column if not exists recovery_pct numeric(5,2);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'sales_return_items_recovery_pct_range') then
    alter table sales_return_items
      add constraint sales_return_items_recovery_pct_range
      check (recovery_pct is null or (recovery_pct >= 0 and recovery_pct <= 100));
  end if;
end $$;

comment on column sales_return_items.recovery_pct is
  'Per-line credit for a damage return, as a percentage of the billed value. Null means the org''s breakage_recovery_pct (db/66).';

-- The lines view gains it. A view may only ever have columns APPENDED.
drop view if exists v_return_lines cascade;
create or replace view v_return_lines as
select ri.id, ri.return_id, ri.item_id, i.item_code, i.name as item_name, i.units_per_box,
       ri.qty, ri.qty / nullif(i.units_per_box, 0) as boxes, ri.uom_id, ri.qty_base, ri.old_rate, ri.new_rate, ri.amount,
       ri.line_no,
       ri.recovery_pct
from sales_return_items ri join items i on i.id = ri.item_id;
alter view v_return_lines set (security_invoker = on);
grant select on v_return_lines to authenticated, anon;

create or replace function save_sales_return(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; v_kind return_kind; v_loc uuid; v_inv uuid; v_cust uuid;
  l jsonb; n int := 0; it items%rowtype; v_qty numeric; v_amt numeric; v_total numeric := 0; v_rate numeric; v_new numeric;
  v_pct numeric; v_cust_name text; v_no text; v_date date; v_line_pct numeric;
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
                     || coalesce(round(ri.new_rate, 2)::text, '-') || '|'
                     || coalesce(round(ri.recovery_pct, 2)::text, '-') as sig
                from sales_return_items ri where ri.return_id = v_id) a;

      -- Built the way the line loop below builds the row, so the same return
      -- sent twice compares equal however the screen phrased it.
      select coalesce(array_agg(sig order by sig), '{}') into v_new_lines
        from (select (x->>'item_id') || '|'
                     || round(coalesce(nullif(x->>'boxes','')::numeric, 0) * i.units_per_box, 3)::text || '|'
                     || round(coalesce(nullif(x->>'rate','')::numeric, i.unit_rate, 0), 2)::text || '|'
                     || coalesce(round(nullif(x->>'new_rate','')::numeric, 2)::text, '-') || '|'
                     || coalesce(round(nullif(x->>'recovery_pct','')::numeric, 2)::text, '-') as sig
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
    -- What this one damaged lot is worth, as a percentage of what it was
    -- billed at. Blank falls back to the shop's usual figure, so a return
    -- typed the old way behaves exactly as it did.
    v_line_pct := coalesce(nullif(l->>'recovery_pct','')::numeric, v_pct);
    if v_line_pct < 0 or v_line_pct > 100 then
      raise exception 'Line %: the credit must be between 0 and 100 per cent of the billed value, not %', n, v_line_pct;
    end if;
    v_amt := case v_kind
      when 'fresh_return'    then round(v_qty * v_rate, 2)
      when 'damage_return'   then round(v_qty * v_rate * v_line_pct / 100, 2)
      when 'rate_difference' then round(v_qty * (v_rate - coalesce(v_new, v_rate)), 2)
    end;
    if v_kind = 'rate_difference' and v_new is null then
      raise exception 'Line %: a rate difference needs the new rate', n;
    end if;
    insert into sales_return_items (return_id, item_id, qty, uom_id, old_rate, new_rate, amount, recovery_pct)
    values (v_id, it.id, v_qty, it.base_uom_id, v_rate, v_new, v_amt,
            case when v_kind = 'damage_return' then v_line_pct end);
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

