-- ============================================================
-- JYOTHI FOODS ERP — 59: A PURCHASE CANNOT BE CORRECTED AT ALL
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- db/58 rewrote unpost_purchase_stock to net the bill's old stock rows into one
-- reversing row per product and godown, dated on the bill's own date, so that
-- correcting a bill no longer reads as a fresh purchase in the stock report.
-- That was right. But to carry the author onto the netted row it wrote
--
--     max(created_by)
--
-- and created_by is a uuid. Postgres has no max() for uuid, so the statement
-- never gets as far as running:
--
--     ERROR:  function max(uuid) does not exist
--
-- which means every purchase edit fails outright the moment db/58 is applied —
-- the one thing db/58 was meant to make safe. It is not a figure that comes out
-- wrong; nothing is saved at all, and save_purchase rolls back whole.
--
-- The fix also settles whose row it is. A reversal is not something the person
-- who typed the bill in September did; it is something the person correcting it
-- is doing now, and that is who the row should name. Where there is no staff
-- record to point at — a correction run by the owner's tooling rather than from
-- the screen — it falls back to the author of the rows being taken back, which
-- is what db/53 recorded.
-- ============================================================

create or replace function unpost_purchase_stock(p_purchase uuid, p_on date default null)
returns int language plpgsql as $$
declare v_net numeric; n int := 0;
begin
  select coalesce(sum(qty_base), 0) into v_net
    from stock_ledger where ref_table = 'purchases' and ref_id = p_purchase;
  if v_net = 0 then return 0; end if;   -- never posted, or already taken back

  -- One row per product and godown, dated on the bill's own date unless the
  -- caller names another, so the correction lands where the purchase was and
  -- not on today's report (db/58).
  insert into stock_ledger (org_id,item_id,location_id,txn_type,txn_date,qty_base,rate,ref_table,ref_id,created_by)
  select org_id, item_id, location_id, 'purchase'::stock_txn_type,
         coalesce(p_on, max(txn_date)),
         -sum(qty_base), max(rate), 'purchases', ref_id,
         -- The person making the correction owns it. (array_agg(...))[1] is the
         -- uuid equivalent of the max() that could not work: the author of the
         -- newest row being reversed.
         coalesce(my_staff_id(), (array_agg(created_by order by id desc))[1])
    from stock_ledger
   where ref_table = 'purchases' and ref_id = p_purchase
   group by org_id, item_id, location_id, ref_id
  having sum(qty_base) <> 0;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function unpost_purchase_stock(uuid, date) to authenticated;
