-- ============================================================
-- JYOTHI FOODS ERP — WHY IS A SAVE TIMING OUT?
--
-- Paste the whole file into the Supabase SQL editor and send one screenshot of
-- the result. It changes nothing: every statement here only reads.
--
-- It was written for "canceling statement due to statement timeout" on
-- save_purchase, where the function itself is not slow — forty milliseconds on
-- a database of four hundred purchases — so the time is being spent WAITING,
-- and the question is what for.
--
-- Read the `problem` column first. Rows marked FOUND are the answer; rows
-- marked ok are what was ruled out, which is worth keeping in the screenshot
-- because it says where not to look next.
-- ============================================================

with

-- 1. Somebody holding a lock while doing nothing. The usual cause of a
--    deterministic timeout on one document type: a session that opened a
--    transaction, took the numbering row, and went to sleep. It is one row,
--    held for microseconds in normal use.
idle_in_txn as (
  select pid, usename, state, now() - xact_start as open_for, left(coalesce(query, ''), 120) as last_query
    from pg_stat_activity
   where state in ('idle in transaction', 'idle in transaction (aborted)')
     and xact_start is not null
),

-- 2. A prepared transaction nobody committed. These survive restarts and hold
--    their locks for ever; they will never clear on their own.
prepared as (select gid, prepared, owner from pg_prepared_xacts),

-- 3. Anything actually blocked right now, and by whom.
blocked as (
  select a.pid, left(coalesce(a.query, ''), 120) as waiting_on,
         pg_blocking_pids(a.pid) as blocked_by, now() - a.query_start as waiting_for
    from pg_stat_activity a
   where cardinality(pg_blocking_pids(a.pid)) > 0
),

-- 4. Locks on the numbering table specifically — the row save_purchase waits
--    for before it does anything else.
ns_locks as (
  select l.pid, l.mode, l.granted
    from pg_locks l join pg_class c on c.oid = l.relation
   where c.relname = 'number_series'
),

-- 5. Dead rows that never got vacuumed turn a small table into a slow scan.
bloat as (
  select relname, n_live_tup, n_dead_tup, last_autovacuum
    from pg_stat_user_tables
   where n_dead_tup > greatest(n_live_tup, 1000)
),

-- 6. How big the shop's tables actually are, biggest first. A save that is
--    genuinely slow rather than blocked shows up here.
sizes as (
  select relname, n_live_tup, pg_size_pretty(pg_total_relation_size(relid)) as size,
         row_number() over (order by pg_total_relation_size(relid) desc) as rn
    from pg_stat_user_tables
),

-- 7. What the timeouts are set to, so the numbers above can be read against
--    something.
settings as (
  select name, setting from pg_settings
   where name in ('statement_timeout', 'lock_timeout', 'idle_in_transaction_session_timeout')
)

select * from (
  select 1 as ord, 'FOUND  sleeping transaction' as problem,
         format('pid %s (%s) has had a transaction open for %s. Last thing it ran: %s', pid, usename, open_for, last_query) as detail
    from idle_in_txn
  union all
  select 1, 'ok     sleeping transaction', 'none — no session is sitting on an open transaction'
   where not exists (select 1 from idle_in_txn)

  union all
  select 2, 'FOUND  prepared transaction',
         format('%s, prepared %s by %s. This holds its locks for ever: rollback prepared ''%s'';', gid, prepared, owner, gid)
    from prepared
  union all
  select 2, 'ok     prepared transaction', 'none'
   where not exists (select 1 from prepared)

  union all
  select 3, 'FOUND  blocked right now',
         format('pid %s waiting %s, blocked by %s. Running: %s', pid, waiting_for, blocked_by, waiting_on)
    from blocked
  union all
  select 3, 'ok     blocked right now', 'nothing is waiting on anything'
   where not exists (select 1 from blocked)

  union all
  select 4, 'note   lock on number_series',
         format('pid %s holds %s (granted: %s)', pid, mode, granted)
    from ns_locks
  union all
  select 4, 'ok     lock on number_series', 'no locks held on the numbering table'
   where not exists (select 1 from ns_locks)

  union all
  select 5, 'FOUND  table never vacuumed',
         format('%s: %s dead rows against %s live, last autovacuum %s', relname, n_dead_tup, n_live_tup, coalesce(last_autovacuum::text, 'never'))
    from bloat
  union all
  select 5, 'ok     table never vacuumed', 'no table is mostly dead rows'
   where not exists (select 1 from bloat)

  union all
  select 6, 'size   ' || relname, format('%s rows, %s', n_live_tup, size) from sizes where rn <= 8

  union all
  select 7, 'set    ' || name, setting from settings
) r
order by ord, problem, detail;
