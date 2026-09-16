-- ============================================================
-- JYOTHI FOODS ERP — 45: resync_doc_numbers() COULD NOT BE RUN ANYWHERE
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
--   ERROR: Not signed in to an organisation
--   CONTEXT: PL/pgSQL function resync_doc_numbers() line 9
--
-- 44 shipped a repair nobody could run. It asked my_org_id(), which reads
-- auth.uid(), and the Supabase SQL Editor has no JWT — so auth.uid() is null,
-- the org is null, and it refused. There is no button for it in the app either.
-- A repair that cannot be reached from the one place a repair gets done is not
-- a repair.
--
-- The two ways in need opposite things, which is the whole trap:
--
--   set_license_plan()     is_service_call(), i.e. auth.uid() IS NULL.
--                          Works in the SQL Editor, refuses from the app.
--   resync_doc_numbers()   my_org_id(), i.e. auth.uid() IS NOT NULL.
--                          Works in the app, refuses in the SQL Editor.
--
-- This one belongs in both. Signed in, it does your own org and wants Setup
-- rights. From the editor, with no JWT, it takes the org id you name.
--
-- DROP FIRST, and this matters: adding a defaulted argument to an existing
-- function does not replace it, it adds a second one beside it, and
-- resync_doc_numbers() would then be ambiguous — "function is not unique", the
-- exact fault check.sql has a section for.
-- ============================================================

drop function if exists resync_doc_numbers();

create or replace function resync_doc_numbers(p_org uuid default null)
returns table (doc_type text, was bigint, now_at bigint)
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid;
  ns    record;
  h     record;
  v_max bigint;
  v_pat text;
begin
  v_org := coalesce(p_org, my_org_id());
  if v_org is null then
    raise exception 'Which organisation? From the SQL Editor there is nobody signed in, so name it: select * from resync_doc_numbers((select id from orgs limit 1));';
  end if;
  if not exists (select 1 from orgs where id = v_org) then
    raise exception 'No organisation with that id';
  end if;

  -- Signed in: your own org only, and only somebody who may edit Setup. From
  -- the editor there is no session to check, and whoever holds the database
  -- password can do anything to it anyway.
  if not is_service_call() then
    if v_org is distinct from my_org_id() then
      raise exception 'Cannot renumber another organisation' using errcode = '42501';
    end if;
    if not can_edit('setup') then
      raise exception 'Only somebody who can edit Setup can resynchronise the numbering' using errcode = '42501';
    end if;
  end if;

  for ns in select * from number_series where org_id = v_org order by doc_type loop
    select * into h from doc_no_home(ns.doc_type);
    continue when h.tbl is null;

    -- Only numbers shaped like this series: prefix, digits, suffix. A supplier's
    -- own bill number typed onto a purchase must not drag the counter with it.
    v_pat := '^' || regexp_replace(coalesce(ns.prefix, ''), '([][^$.|?*+(){}\\])', '\\\1', 'g')
                 || '[0-9]+'
                 || regexp_replace(coalesce(ns.suffix, ''), '([][^$.|?*+(){}\\])', '\\\1', 'g') || '$';

    execute format(
      'select max(nullif(regexp_replace(%I, ''[^0-9]'', '''', ''g''), '''')::bigint)
         from %I where org_id = $1 and %I ~ $2', h.col, h.tbl, h.col)
      into v_max using v_org, v_pat;

    if v_max is not null and v_max >= ns.next_number then
      doc_type := ns.doc_type;
      was      := ns.next_number;
      now_at   := v_max + 1;
      update number_series set next_number = v_max + 1 where id = ns.id;
      return next;
    end if;
  end loop;
end $$;

revoke execute on function resync_doc_numbers(uuid) from public, anon;
grant  execute on function resync_doc_numbers(uuid) to authenticated;
