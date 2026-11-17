-- ============================================================
-- WHAT DID THE DAMAGE RETURNS ACTUALLY SAVE?
--
-- Read-only. Changes nothing, safe to run any time.
--
-- "Damage modified but not working" can mean two different faults and they
-- have different fixes, so this shows which one it is:
--
--   * the figure reached the database and the screen is showing it wrong
--   * the figure never reached the database at all
--
-- Paste the whole file into the Supabase SQL editor.
-- ============================================================

-- 1. The shop's own default. Every damage line with no figure of its own is
--    credited at this. It should be 50 unless somebody changed it in
--    Setup → Business profile.
-- No auth.uid() anywhere in this file: the SQL editor runs as the database
-- owner with nobody signed in, so anything that asks who the user is comes
-- back null and the query returns nothing at all.
select o.name as shop,
       o.breakage_recovery_pct || ' %' as "damage credit default",
       case when o.breakage_recovery_pct = 50 then 'as expected'
            else 'CHANGED — this is what a blank line is credited at' end as note
  from orgs o
 order by o.name;

-- 2. The last twenty damage return lines, with what was stored against each.
--
--    Read `credit %` first:
--      a number  → the figure was saved; expected credit = qty x rate x that
--      (blank)   → no figure was sent, so the shop default above was used
--
--    Then check `credit saved` against `credit expected`. If they differ, the
--    stored amount was worked out from a different percentage than the one
--    now on the row — which means the line was saved before the percentage
--    was changed, and re-saving that return will correct it.
select o.name as shop,
       r.return_no,
       r.return_date,
       c.name as customer,
       i.item_code,
       i.name as item,
       ri.qty,
       ri.old_rate as rate,
       coalesce(ri.recovery_pct::text, '(blank — uses the shop default)') as "credit %",
       ri.amount as "credit saved",
       round(ri.qty * ri.old_rate
             * coalesce(ri.recovery_pct, o.breakage_recovery_pct) / 100, 2) as "credit expected",
       case
         when ri.amount = round(ri.qty * ri.old_rate
                                * coalesce(ri.recovery_pct, o.breakage_recovery_pct) / 100, 2)
           then 'agrees'
         else 'DOES NOT AGREE — re-save this return'
       end as verdict
  from sales_returns r
  join orgs o on o.id = r.org_id
  join sales_return_items ri on ri.return_id = r.id
  join items i on i.id = ri.item_id
  left join customers c on c.id = r.customer_id
 where r.kind = 'damage_return'
 order by r.return_date desc, r.created_at desc, i.item_code
 limit 20;
