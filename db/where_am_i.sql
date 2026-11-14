-- ============================================================
-- WHICH MIGRATIONS ARE ALREADY IN?
--
-- Read-only. Changes nothing, safe to run any time, safe to run twice.
--
-- Paste the whole file into the Supabase SQL editor. It looks for one thing
-- each migration creates and reports APPLIED or NOT YET, so a run can be
-- resumed from the right place instead of from a guess — and so a file is not
-- run twice, which is how a function ends up back at an older version.
--
-- Run the ones marked NOT YET, in number order, lowest first. Then run
-- db/74 last, whatever the rest of this says.
-- ============================================================
with checks(seq, file, what, applied) as (
  values
    (65, '65_vehicle_and_supplier_reports.sql', 'vehicle and supplier reports',
         to_regprocedure('public.vehicle_report(date, date, uuid)') is not null
         or to_regprocedure('public.vehicle_key(text)') is not null),

    (66, '66_damage_credit_per_line.sql', 'damage credit per line',
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'sales_return_items'
                    and column_name = 'recovery_pct')),

    (67, '67_party_both_sides.sql', 'a customer who is also a supplier',
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'customers'
                    and column_name = 'supplier_id')),

    (68, '68_backup_says_why.sql', 'a failed backup says why',
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'backups'
                    and column_name = 'error')),

    (69, '69_backup_is_never_capped.sql', 'backup works on every plan',
         -- db/69 drops the plan policies that stopped a capped shop recording
         -- a backup at all.
         to_regclass('public.backups') is not null
         and not exists (select 1 from pg_policy
                          where polrelid = 'public.backups'::regclass and polname = 'plan_insert')),

    (70, '70_message_credits.sql', 'prepaid message credits',
         to_regclass('public.credit_ledger') is not null),

    (71, '71_cost_and_wages_are_not_public.sql', 'cost and wages not public',
         to_regprocedure('public.item_cost(uuid)') is not null),

    (72, '72_custom_roles.sql', 'the shop names its own jobs',
         to_regclass('public.roles') is not null),

    (73, '73_payroll.sql', 'overtime, salaries, advances, wages in the books',
         to_regclass('public.wage_payments') is not null),

    (74, '74_settle_the_grown_functions.sql', 'the three grown functions settled',
         -- Right only when staff_list has all eighteen columns AND the payroll
         -- tables are in the backup list, which is what db/74 guarantees.
         (select count(*) from pg_proc p, unnest(p.proargmodes) m
           where p.oid = to_regprocedure('public.staff_list()') and m = 't') = 18
         and to_regprocedure('public.snapshot_tables()') is not null
         and array_position(snapshot_tables(), 'wage_payments') is not null)
)
select case when applied then 'APPLIED ' else '>> RUN THIS' end as status,
       'db/' || file as file,
       what
  from checks
 order by seq;
