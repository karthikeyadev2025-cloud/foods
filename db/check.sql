-- ============================================================
-- WHERE HAS THIS DATABASE GOT TO?
--
-- Paste the whole file into the Supabase SQL Editor and run it. It changes
-- nothing. It reports which migrations are actually in, by looking for one
-- object each file creates — so "ok" means that file really finished, not
-- that somebody remembers running it.
--
-- Read the first result top to bottom. The first MISSING row is where to
-- start, and the files must go in this order: each one builds on the last.
-- ============================================================
with expected(ord, file, kind, obj, detail) as (
  values
    ( 1, '01_schema.sql',       'table',    'orgs',                        'organisations, staff, items, customers'),
    ( 2, '02_logic.sql',        'function', 'qty_to_pieces',               'units, rates, stock posting'),
    ( 3, '04_extended.sql',     'table',    'production_batches',          'production, trips, messaging tables'),
    ( 4, '03_rls.sql',          'function', 'my_org_id',                   'row-level security — runs AFTER 04'),
    ( 5, '05_fixes.sql',        'function', 'recompute_invoice_totals',    'starter fixes'),
    ( 6, '06_setup.sql',        'function', 'bootstrap_org',               'permissions, first-run setup'),
    ( 7, '07_import.sql',       'function', 'import_rows',                 'the Excel importer'),
    ( 8, '08_masters.sql',      'view',     'v_item_list',                 'item and customer lists'),
    ( 9, '09_transactions.sql', 'function', 'save_invoice',                'invoices, receipts, payments'),
    (10, '10_stock_trips.sql',  'function', 'closing_stock_report',        'van trips and loading'),
    (11, '11_production.sql',   'function', 'save_recipe',                 'batches and variance'),
    (12, '12_reports.sql',      'function', 'receipts_register',           'the reports'),
    (13, '13_messaging.sql',    'table',    'messaging_settings',          'WhatsApp — Hey Nikki'),
    (14, '14_accounts.sql',     'function', 'ensure_system_accounts',      'books and ledgers'),
    (15, '15_documents.sql',    'table',    'quotations',                  'quotations, orders, challans'),
    (16, '16_inventory.sql',    'table',    'item_batches',                'batches, barcodes, counts'),
    (17, '17_owner.sql',        'table',    'backups',                     'print designer, backup, audit'),
    (18, '18_licensing.sql',    'function', 'issue_license',               'licence keys'),
    (19, '19_phase3.sql',       'table',    'incentive_schemes',           'route profit, incentives, driver phone'),
    (20, '20_voice.sql',        'column',   'messaging_settings.voice_enabled', 'voice calls'),
    (21, '21_plans.sql',        'function', 'plan_features',               'the three licence plans'),
    (22, '22_attendance.sql',   'table',    'punchly_settings',            'attendance and Punchly'),
    (23, '23_extension_fix.sql','fixed',    'issue_license',               'the pgcrypto fix — only needed on a database built before it'),
    (24, '24_plan_trial.sql',   'column',   'orgs.plan_full_until',        'the 10-day everything-open trial'),
    (25, '25_daily_cap.sql',    'function', 'claim_queued_messages',       'the message cap counts a real day, not 05:30 to 05:30'),
    (26, '26_repair.sql',       'function', 'module_feature',              'the one-file repair — 20 through 28 in order'),
    (27, '27_attendance_in_starter.sql', 'function', 'plan_features',      'attendance included in Starter'),
    (28, '28_product_images.sql','column',  'items.image_url',             'product photos and the rate card'),
    (29, '29_line_measure.sql', 'function', 'items_needing_measure',       'a unit with no weight names itself instead of failing on qty_base'),
    (30, '30_invoice_edit.sql', 'function', 'reopen_invoice',              'edit a confirmed sale invoice'),
    (31, '31_item_code_serial.sql','function','next_item_code',            'the next item code, filled in for you'),
    (32, '32_purchase_auto_no.sql','fixed', 'save_purchase#next_doc_no',   'a purchase with no supplier bill number numbers itself'),
    (33, '33_document_search.sql','function','search_documents',           'one search across every kind of bill'),
    (34, '34_search_any_detail.sql','fixed','search_documents#invoice_items', 'search by phone, amount, item, vehicle, cheque or note'),
    (35, '35_search_masters.sql','fixed',   'search_documents#v_supplier_list', 'the search finds people and products, not only their bills'),
    (36, '36_delete_and_void.sql','function','delete_master',              'delete and cancel on every screen')
)
select
  e.ord                                          as "#",
  e.file,
  case when f.found then 'ok' else 'MISSING' end as status,
  e.detail
from expected e
cross join lateral (
  select case e.kind
    when 'table'    then to_regclass('public.' || e.obj) is not null
    when 'view'     then to_regclass('public.' || e.obj) is not null
    when 'function' then exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = e.obj)
    when 'column'   then exists (
      select 1 from information_schema.columns c
       where c.table_schema = 'public'
         and c.table_name  = split_part(e.obj, '.', 1)
         and c.column_name = split_part(e.obj, '.', 2))
    -- 23 restates existing functions rather than creating new ones, so look at what
    -- they are made of. Two traps here, both hit while writing this:
    --   • Test for the fix being PRESENT, not the old call being absent. The fixed
    --     functions carry a comment naming gen_random_bytes to explain the bug, so
    --     searching for its absence matches that comment and calls a fixed database
    --     broken.
    --   • Read prosrc, not pg_get_functiondef(). The planner is free to evaluate that
    --     call before the schema filter, and it throws on the aggregates in
    --     pg_catalog: "array_agg is an aggregate function". prosrc is a plain column.
    -- A file that only REPLACES an existing function proves itself by a phrase
    -- its new body contains: 'name#phrase', or just 'name' for the original
    -- pgcrypto fix. prosrc, not pg_get_functiondef(), which throws on aggregates.
    when 'fixed'    then exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = split_part(e.obj, '#', 1) and p.prokind = 'f'
         and p.prosrc like '%' || coalesce(nullif(split_part(e.obj, '#', 2), ''), 'gen_random_uuid') || '%')
  end as found
) f
order by e.ord;

-- ── Anything of ours defined twice?
--
-- A function that gains or loses an argument and is then re-applied leaves
-- both copies behind, because `create or replace` cannot change an argument
-- list — it adds a second function beside the first. Calls then fail with
-- "function ... is not unique". Extension functions (pgcrypto and friends)
-- have legitimate overloads and are excluded.
--
-- This should return no rows. If it returns one, drop the older signature.
select p.proname                                                   as duplicated_function,
       count(*)                                                    as copies,
       string_agg(pg_get_function_identity_arguments(p.oid), '   |   ' order by p.oid) as signatures
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and not exists (
     select 1 from pg_depend d
      where d.objid = p.oid and d.deptype = 'e')     -- belongs to an extension
 group by p.proname
having count(*) > 1;

-- ── The organisation, its plan and its licence.
--
-- Read through to_jsonb so this still answers on a database that has not
-- reached 21 yet — naming the columns directly would make this diagnostic
-- fail on exactly the databases it is meant to diagnose.
select to_jsonb(o)->>'name'               as organisation,
       to_jsonb(o)->>'license_plan'       as plan,
       to_jsonb(o)->>'license_valid_till' as valid_till,
       (to_jsonb(o)->>'license_key') is not null as has_key
  from orgs o;
