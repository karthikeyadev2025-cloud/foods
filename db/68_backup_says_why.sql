-- ============================================================
-- JYOTHI FOODS ERP — 68: A FAILED BACKUP NEVER SAID WHY
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "There are errors occurring during the backup process." There is no way to
-- find out what they were. A backup that fails writes status = 'failed' and
-- nothing else: the screen shows a red badge against a timestamp, the reason
-- is thrown away, and the nightly ones fail unwatched in the small hours with
-- nobody to read the error even if it had been shown.
--
-- So the reason is kept. The next failure explains itself on the screen,
-- whether anybody was watching or not, and this stops being a conversation
-- that starts with "it says it failed".
--
-- Two things worth knowing while reading a failure, both of which look like
-- bugs and are not:
--
--   * Backup is part of Owner control, which is a FULL-plan feature (db/21).
--     A shop capped to Starter or Growth is refused by name — "Owner control
--     is not part of your licence" — and that is the licence talking, not a
--     fault. Automatic backups run as the service and are never capped, so
--     they keep going when the manual button will not.
--
--   * org_snapshot() builds one JSON document of every row the org owns. On a
--     database carrying a lot of history that is slow, and a statement
--     timeout surfaces here as a failed backup rather than as a timeout. The
--     reason now says which it was.
-- ============================================================

alter table backups
  add column if not exists error text;

comment on column backups.error is
  'Why this backup failed, in the words of whatever refused it. Null when it did not fail (db/68).';

-- The list the screen reads. A view may only ever have columns APPENDED.
do $$
begin
  if to_regclass('public.v_backups') is not null then
    drop view v_backups cascade;
  end if;
end $$;

create or replace view v_backups as
select b.id, b.org_id, b.file_path, b.size_bytes, b.status, b.is_auto,
       b.created_by, s.full_name as created_by_name, b.created_at,
       b.error
from backups b
left join staff s on s.id = b.created_by;
alter view v_backups set (security_invoker = on);
grant select on v_backups to authenticated;
