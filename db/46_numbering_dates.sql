-- ============================================================
-- JYOTHI FOODS ERP — 46: A COUNTER THAT RESETS NEEDS A DATE TO RESET INTO
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- Setup → Numbering at the shop reads:
--
--   doc_type  prefix  width  next_number  reset_period
--   invoice   (none)      2            5  daily
--   purchase  (none)      2            5  daily
--
-- That is the 23505 from the till, written down. The prefix is a fixed piece of
-- text, so "reset every day" can only mean: tomorrow morning start again at 01 —
-- and 01 is on a bill from last week. Every reset walks the counter back over
-- numbers that are already used. 44 stopped it breaking the sale (a number in
-- use is skipped), but the reset still does nothing except make the counter
-- climb, and a two-digit series climbs into a third digit by bill 100.
--
-- The reset was never wrong to want. What was missing is the date it resets
-- into. A prefix may now carry {YYYY} {YY} {MM} {DD}, which are filled in when
-- the number is handed out:
--
--   prefix '{YY}{MM}{DD}/'  reset daily    → 260916/01, and tomorrow 260917/01
--   prefix '{YYYY}-'        reset yearly   → 2026-0001, and in January 2027-0001
--
-- Both restart exactly as intended and neither can collide, because the day is
-- part of the number. Without a token a reset is refused — the app will not
-- save one, and resync_doc_numbers() names any that are already stored.
--
-- resync_doc_numbers() also changes shape, and that is the other half of this
-- file. It returned rows ONLY for counters it moved, so "no rows" meant three
-- different things at once — everything is fine, this org has no numbering, or
-- you named the wrong organisation — and there was no way to tell which. It now
-- reports EVERY series with what it found and what it did. No rows now means
-- one thing only: that org has no number series at all.
--
-- DROP FIRST: the return type changes, and `create or replace` cannot change a
-- return type. It refuses with "cannot change return type of existing function".
-- ============================================================

-- Fill {YYYY} {YY} {MM} {DD} in from a date. {YYYY} must be replaced before
-- {YY}, or '{YYYY}' becomes '26YY}'.
create or replace function doc_no_stamp(p_text text, p_on date default current_date)
returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(p_text, ''),
           '{YYYY}', to_char(p_on, 'YYYY')),
           '{YY}',   to_char(p_on, 'YY')),
           '{MM}',   to_char(p_on, 'MM')),
           '{DD}',   to_char(p_on, 'DD'));
$$;

-- Text to match literally inside a regular expression.
create or replace function regex_literal(p_text text)
returns text language sql immutable as $$
  select regexp_replace(coalesce(p_text, ''), '([][^$.|?*+(){}\\])', '\\\1', 'g');
$$;

/**
 * Why this series cannot reset the way it is set, in words for the shop.
 * Null when there is nothing wrong with it.
 *
 * A reset is safe only when the number carries every date part that has to
 * change. Monthly needs the year too: without it, January 2027 lands straight
 * back on January 2026's numbers.
 */
create or replace function numbering_warning(p_reset text, p_prefix text, p_suffix text)
returns text language plpgsql immutable as $$
declare
  t    text := coalesce(p_prefix, '') || coalesce(p_suffix, '');
  need text;
  per  text;
begin
  if coalesce(p_reset, 'never') = 'never' then return null; end if;

  select n, p into need, per from (values
    ('yearly',  '{YYYY}',         'year'),
    ('monthly', '{YYYY}{MM}',     'month'),
    ('daily',   '{YYYY}{MM}{DD}', 'day')
  ) as v(r, n, p) where v.r = p_reset;
  if need is null then return null; end if;          -- a period we do not know

  if (t like '%{YYYY}%' or t like '%{YY}%')
     and (p_reset = 'yearly' or t like '%{MM}%')
     and (p_reset <> 'daily' or t like '%{DD}%')
  then return null; end if;

  return format(
    'The counter goes back to 1 every %s, but the number carries no date — so it '
    'lands on numbers already used. Put %s in the prefix, or set Reset to never.',
    per, need);
end $$;

-- ── handing out a number ────────────────────────────────────────────────────
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

  select * into ns from number_series
   where org_id = p_org and doc_type = p_doc_type for update;
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

-- ── the repair, which now reports on everything ─────────────────────────────
drop function if exists resync_doc_numbers(uuid);
drop function if exists resync_doc_numbers();

/**
 * Walk every counter past the documents that already exist, and say what was
 * found for each one whether it moved or not.
 *
 * Reads only the numbers shaped like the series itself — prefix, digits, suffix
 * — so a supplier's own bill number typed onto a purchase does not drag the
 * counter somewhere it has no business being. The running number is read by
 * cutting the prefix and suffix off, not by stripping non-digits: a prefix of
 * '{YYYY}-' is all digits once it is filled in, and stripping would have read
 * 2026-0007 as twenty-six million.
 *
 * On a dated series only THIS period's documents are looked at, which is the
 * point of dating it: September's counter has no business being dragged up by
 * August's bills, because 202609/0001 and 202608/0001 are different numbers.
 */
create or replace function resync_doc_numbers(p_org uuid default null)
returns table (
  doc_type         text,
  next_number_is   text,
  counter_was      bigint,
  counter_now      bigint,
  highest_document bigint,
  action           text,
  warning          text)
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid;
  ns    record;
  h     record;
  v_max bigint;
  v_pat text;
  v_pre text;
  v_suf text;
begin
  v_org := coalesce(p_org, my_org_id());
  if v_org is null then
    raise exception 'Which organisation? Nobody is signed in — in the SQL Editor there never is. Run  select id, name from orgs;  and then  select * from resync_doc_numbers(''<the id>'');';
  end if;
  if not exists (select 1 from orgs where id = v_org) then
    raise exception 'No organisation with that id. Run  select id, name from orgs;  to see them.';
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

  for ns in select * from number_series s where s.org_id = v_org order by s.doc_type loop
    v_pre := doc_no_stamp(ns.prefix);
    v_suf := doc_no_stamp(ns.suffix);

    doc_type         := ns.doc_type;
    counter_was      := ns.next_number;
    counter_now      := ns.next_number;
    highest_document := null;
    next_number_is   := v_pre || lpad(ns.next_number::text, ns.width, '0') || v_suf;
    warning          := numbering_warning(ns.reset_period, ns.prefix, ns.suffix);

    select * into h from doc_no_home(ns.doc_type);
    if h.tbl is null then
      action := 'not checked — this kind of document is not numbered from a table';
      return next;
      continue;
    end if;

    v_pat := '^' || regex_literal(v_pre) || '[0-9]+' || regex_literal(v_suf) || '$';

    execute format(
      'select max(substring(%I from $3 for length(%I) - $4)::bigint)
         from %I where org_id = $1 and %I ~ $2', h.col, h.col, h.tbl, h.col)
      into v_max
      using v_org, v_pat, length(v_pre) + 1, length(v_pre) + length(v_suf);

    highest_document := v_max;

    if v_max is null then
      action := 'nothing numbered yet';
    elsif v_max >= ns.next_number then
      update number_series set next_number = v_max + 1 where id = ns.id;
      counter_now    := v_max + 1;
      next_number_is := v_pre || lpad(counter_now::text, ns.width, '0') || v_suf;
      action         := 'MOVED — the counter was standing on numbers already used';
    else
      action := 'already ahead';
    end if;

    return next;
  end loop;
end $$;

revoke execute on function resync_doc_numbers(uuid) from public, anon;
grant  execute on function resync_doc_numbers(uuid) to authenticated;
