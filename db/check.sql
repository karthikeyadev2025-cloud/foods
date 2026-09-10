-- ============================================================
-- WHERE HAS THIS DATABASE GOT TO?
--
-- Paste the whole file into the Supabase SQL Editor and run it. It changes
-- nothing. It reports which migrations are actually in, by looking for one
-- object each file creates — so "ok" means that file really finished, not
-- that somebody remembers running it.
--
-- ONE table comes back, and the first MISSING row is where to start. The
-- files must go in the order shown: each one builds on the last.
--
-- It is one table on purpose. This file used to end in three separate
-- SELECTs, and the Supabase editor shows only the LAST result — so the
-- migration list, the whole point of the file, was invisible. Everything now
-- arrives in one place: the files, then anything defined twice, then the
-- organisation and its licence.
--
-- HOW A FILE PROVES ITSELF
-- The object looked for has to be one that ONLY that file creates. Ten rows
-- here used to name an object an EARLIER file had already created — so
-- 15_documents.sql reported "ok" on a database where only 04_extended.sql
-- had ever run, because 04 is where the quotations table really is. A check
-- that cannot fail is worse than no check: it is a wrong answer delivered
-- confidently. Every probe below is now unique to its own file.
-- ============================================================
with expected(ord, file, kind, obj, detail) as (
  values
    ( 1, '01_schema.sql',       'table',    'orgs',                        'organisations, staff, items, customers'),
    ( 2, '02_logic.sql',        'function', 'qty_to_pieces',               'units, rates, stock posting'),
    ( 3, '04_extended.sql',     'table',    'journal_entries',             'ledgers, cheques, quotations, batches — runs BEFORE 03'),
    ( 4, '03_rls.sql',          'function', 'my_org_id',                   'row-level security — runs AFTER 04'),
    ( 5, '05_fixes.sql',        'function', 'recompute_invoice_totals',    'starter fixes'),
    ( 6, '06_setup.sql',        'function', 'bootstrap_org',               'permissions, first-run setup'),
    ( 7, '07_import.sql',       'function', 'import_rows',                 'the Excel importer'),
    ( 8, '08_masters.sql',      'view',     'v_item_list',                 'item and customer lists'),
    ( 9, '09_transactions.sql', 'function', 'save_invoice',                'invoices, receipts, payments'),
    (10, '10_stock_trips.sql',  'function', 'settle_trip',                 'van trips and loading'),
    (11, '11_production.sql',   'function', 'save_recipe',                 'batches and variance'),
    (12, '12_reports.sql',      'function', 'outstanding_ageing',          'the reports'),
    (13, '13_messaging.sql',    'table',    'messaging_settings',          'WhatsApp — Hey Nikki'),
    (14, '14_accounts.sql',     'function', 'save_transfer',               'books and ledgers'),
    (15, '15_documents.sql',    'function', 'save_quotation',              'quotations, orders, challans, price lists'),
    (16, '16_inventory.sql',    'table',    'stock_counts',                'batches, barcodes, counts'),
    (17, '17_owner.sql',        'function', 'org_snapshot',                'print designer, backup, audit'),
    (18, '18_licensing.sql',    'function', 'issue_license',               'licence keys'),
    (19, '19_phase3.sql',       'table',    'incentive_schemes',           'route profit, incentives, driver phone'),
    (20, '20_voice.sql',        'column',   'messaging_settings.voice_enabled', 'voice calls'),
    (21, '21_plans.sql',        'function', 'plan_features',               'the three licence plans'),
    (22, '22_attendance.sql',   'table',    'punchly_settings',            'attendance and Punchly'),
    (23, '23_extension_fix.sql','fixed',    'issue_license',               'the pgcrypto fix — only needed on a database built before it'),
    (24, '24_plan_trial.sql',   'column',   'orgs.plan_full_until',        'the 10-day everything-open trial'),
    -- 25 and 27 only restate functions that 13 and 21 already created, so they
    -- prove themselves by a phrase their new body contains.
    (25, '25_daily_cap.sql',    'fixed',    'claim_queued_messages#::date)::timestamp at time zone',
                                                                           'the message cap counts a real day, not 05:30 to 05:30'),
    (26, '26_repair.sql',       'function', 'catalogue_items',             'the one-file repair — 20 through 28 in order'),
    (27, '27_attendance_in_starter.sql', 'fixed', 'plan_features#array[''core'', ''attendance'']',
                                                                           'attendance included in Starter'),
    (28, '28_product_images.sql','column',  'items.image_url',             'product photos and the rate card'),
    (29, '29_line_measure.sql', 'function', 'items_needing_measure',       'a unit with no weight names itself instead of failing on qty_base'),
    (30, '30_invoice_edit.sql', 'function', 'reopen_invoice',              'edit a confirmed sale invoice'),
    (31, '31_item_code_serial.sql','function','next_item_code',            'the next item code, filled in for you'),
    (32, '32_purchase_auto_no.sql','fixed', 'save_purchase#next_doc_no',   'a purchase with no supplier bill number numbers itself'),
    (33, '33_document_search.sql','function','search_documents',           'one search across every kind of bill'),
    (34, '34_search_any_detail.sql','fixed','search_documents#invoice_items', 'search by phone, amount, item, vehicle, cheque or note'),
    (35, '35_search_masters.sql','fixed',   'search_documents#v_supplier_list', 'the search finds people and products, not only their bills'),
    (36, '36_delete_and_void.sql','function','delete_master',              'delete and cancel on every screen'),
    (37, '37_data_health.sql',  'function', 'negative_stock',              'Stock > Problems: negative stock, unusable products, duplicate rows'),
    (38, '38_import_create_lookups.sql', 'fixed', 'import_rows#create_lookups',
                                                                           'an unknown pack type or section no longer throws the whole product away')
),

-- Did each file's own object actually make it?
checked as (
  select e.ord, e.file, e.detail, f.found
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
        -- A file that only REPLACES an existing function proves itself by a
        -- phrase its new body contains: 'name#phrase', or just 'name' for the
        -- original pgcrypto fix. Two traps here, both hit while writing this:
        --   • Test for the fix being PRESENT, not the old call being absent. The
        --     fixed functions carry a comment naming gen_random_bytes to explain
        --     the bug, so searching for its absence matches that comment and
        --     calls a fixed database broken.
        --   • Read prosrc, not pg_get_functiondef(). The planner is free to
        --     evaluate that call before the schema filter, and it throws on the
        --     aggregates in pg_catalog: "array_agg is an aggregate function".
        --     prosrc is a plain column.
        when 'fixed'    then exists (
          select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = split_part(e.obj, '#', 1) and p.prokind = 'f'
             and p.prosrc like '%' || coalesce(nullif(split_part(e.obj, '#', 2), ''), 'gen_random_uuid') || '%')
      end as found
    ) f
),

-- Anything of ours defined twice? A function that gains or loses an argument
-- and is then re-applied leaves both copies behind, because `create or replace`
-- cannot change an argument list — it adds a second function beside the first.
-- Calls then fail with "function ... is not unique". Extension functions
-- (pgcrypto and friends) have legitimate overloads and are excluded.
dupes as (
  select p.proname as fn,
         count(*)  as copies,
         string_agg(pg_get_function_identity_arguments(p.oid), '   |   ' order by p.oid) as signatures
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
   group by p.proname
  having count(*) > 1
)

select * from (
  -- ── the answer, in one line ──
  -- Duplicated functions count as work too: a database can have every file in
  -- and still fail on "function is not unique", so a summary that only counted
  -- the files would say "nothing to run" over the top of a real fault.
  select 0::numeric as ord,
         ''         as step,
         'READ THIS FIRST' as item,
         case when c.behind = 0 and d.n = 0 then 'ok' else 'ACTION' end as status,
         trim(concat_ws(' ',
           case when c.behind = 0
                then format('All %s files are in.', c.total)
                else format('%s of %s files are not in. Run them in number order, starting with %s.',
                            c.behind, c.total, c.first_missing) end,
           case when d.n > 0
                then format('%s function%s defined twice — see the FIX row%s below.',
                            d.n, case when d.n = 1 then ' is' else 's are' end,
                            case when d.n = 1 then '' else 's' end) end,
           case when c.behind = 0 and d.n = 0 then 'Nothing to run.' end)) as detail
    from (select count(*) as total,
                 count(*) filter (where not found) as behind,
                 min(file) filter (where not found) as first_missing
            from checked) c
    cross join (select count(*) as n from dupes) d

  union all
  -- ── file by file ──
  select ord, ord::text, file,
         case when found then 'ok' else 'MISSING' end,
         detail
    from checked

  union all
  -- ── anything defined twice ──
  select 100 + row_number() over (order by fn), '', 'defined twice: ' || fn, 'FIX',
         format('%s copies — %s. Drop the older signature, or calls fail with "function is not unique".', copies, signatures)
    from dupes

  union all
  -- ── the organisation, its plan and its licence ──
  -- Read through to_jsonb so this still answers on a database that has not
  -- reached 21 yet: naming the columns directly would make this diagnostic fail
  -- on exactly the databases it is meant to diagnose.
  -- The plan trial belongs here too. This row used to read "starter plan, valid
  -- until 2027-09-30" and nothing else, while a ten-day clock ran underneath
  -- that would shut Purchases, Quotations, Payments, Production and Vans on a
  -- date nobody had been told. A status of ok over a cliff is a wrong answer.
  select 200 + row_number() over (order by to_jsonb(o)->>'name'), '',
         'organisation: ' || coalesce(to_jsonb(o)->>'name', '?'),
         case when (to_jsonb(o)->>'license_valid_till')::date < current_date then 'EXPIRED'
              when (to_jsonb(o)->>'plan_full_until')::date >= current_date  then 'TRIAL'
              else 'ok' end,
         format('%s plan, %s until %s, licence key %s.%s',
                coalesce(to_jsonb(o)->>'license_plan', 'unknown'),
                case when (to_jsonb(o)->>'license_valid_till')::date < current_date then 'EXPIRED' else 'valid' end,
                coalesce(to_jsonb(o)->>'license_valid_till', '?'),
                case when (to_jsonb(o)->>'license_key') is not null then 'installed' else 'NOT installed' end,
                case when (to_jsonb(o)->>'plan_full_until')::date >= current_date
                     then format(' EVERY screen is open for %s more day(s), until %s — then it drops to %s. To keep them: select set_license_plan(''%s'', ''full'');',
                                 ((to_jsonb(o)->>'plan_full_until')::date - current_date) + 1,
                                 to_jsonb(o)->>'plan_full_until',
                                 coalesce(to_jsonb(o)->>'license_plan', '?'),
                                 o.id)
                     else '' end)
    from orgs o
) report
order by ord;
