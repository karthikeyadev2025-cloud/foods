-- ============================================================
-- JYOTHI FOODS ERP — 56: A BLOCKED NUMBER SERIES SAYS SO
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- Eleven purchase bills sat in the outbox for a week, every one of them reading
--
--     canceling statement due to statement timeout
--
-- which tells a shopkeeper nothing and tells whoever is called in to look
-- almost nothing. save_purchase itself is not slow: on a database built here
-- with four hundred purchases, four thousand lines and the full set of audit
-- triggers, one more save takes forty milliseconds. It was not working slowly.
-- It was waiting.
--
-- next_doc_no takes
--
--     select * from number_series where org_id = ... and doc_type = ...
--       for update
--
-- to stop two tills handing out bill number 7 at the same moment. That is
-- right. But a FOR UPDATE with no timeout waits as long as it is asked to, and
-- if some other session is holding that row and has gone to sleep — a
-- transaction left open, a prepared transaction never committed — then every
-- save of that ONE document type waits until the statement timeout kills it.
-- Which is exactly the shape of the fault: purchases dead, everything else
-- fine, for a week, deterministically. Each doc_type is a separate row, so a
-- stuck lock takes out exactly one kind of document.
--
-- Two changes, neither of which makes the numbering less safe:
--
--   * The wait is capped. Three seconds is far longer than this lock is ever
--     legitimately held — it is one row, held for the microseconds between
--     reading a counter and writing it back.
--
--   * Running out of patience is reported as what it is, in words that name
--     the problem and what to do, instead of arriving as "statement timeout"
--     eight seconds later.
--
-- This does not unstick a lock that is already there; nothing in a migration
-- can. It makes the next occurrence legible in three seconds instead of
-- mysterious in eight. db/diagnose.sql finds the session that is holding it.
--
-- Everything else in this function is db/46's, carried across unchanged: the
-- date tokens, the reset periods, and the collision loop from db/44 that stops
-- a number already on a bill being handed out twice.
-- ============================================================

create or replace function next_doc_no(p_org uuid, p_doc_type text)
returns text language plpgsql security definer set search_path = public as $$
declare
  ns      number_series%rowtype;
  v_reset boolean := false;
  h       record;
  v_pre   text;
  v_suf   text;
  v_no    text;
  v_taken boolean;
  tries   int := 0;
begin
  if p_org is distinct from my_org_id() then
    raise exception 'Cannot number documents for another organisation';
  end if;

  -- Transaction-scoped: it reverts on commit or rollback, so it can never be
  -- left behind on the connection for the next statement to inherit.
  set local lock_timeout = '3s';

  begin
    select * into ns from number_series
     where org_id = p_org and doc_type = p_doc_type for update;
  exception when lock_not_available then
    raise exception
      'The % numbering is locked by something else and did not let go. Nothing was saved. If it keeps happening, somebody has a query or a session open on Setup → Numbering — close it, or run db/diagnose.sql to find it.',
      p_doc_type
      using errcode = '55P03';
  end;

  if not found then
    insert into number_series (org_id, doc_type) values (p_org, p_doc_type)
    returning * into ns;
  end if;

  v_reset := case ns.reset_period
    when 'yearly'  then ns.last_reset is null or date_trunc('year', ns.last_reset)  < date_trunc('year', current_date)
    when 'monthly' then ns.last_reset is null or date_trunc('month', ns.last_reset) < date_trunc('month', current_date)
    when 'daily'   then ns.last_reset is null or ns.last_reset < current_date
    else false end;

  if v_reset then
    update number_series set next_number = 1, last_reset = current_date where id = ns.id;
    ns.next_number := 1;
  end if;

  -- Today's date goes into the number itself, so a series that restarts every
  -- day restarts into numbers nobody has had.
  v_pre := doc_no_stamp(ns.prefix);
  v_suf := doc_no_stamp(ns.suffix);

  select * into h from doc_no_home(p_doc_type);

  loop
    v_no := v_pre || lpad(ns.next_number::text, ns.width, '0') || v_suf;

    if h.tbl is null then
      v_taken := false;                        -- nowhere to look; behave as before
    else
      execute format('select exists (select 1 from %I where org_id = $1 and %I = $2)', h.tbl, h.col)
        into v_taken using p_org, v_no;
    end if;

    exit when not v_taken;

    ns.next_number := ns.next_number + 1;
    tries := tries + 1;
    if tries > 100000 then
      raise exception 'Could not find a free % number after % tries — check Setup → Numbering',
        p_doc_type, tries;
    end if;
  end loop;

  update number_series set next_number = ns.next_number + 1, last_reset = current_date
   where id = ns.id;

  return v_no;
end $$;
