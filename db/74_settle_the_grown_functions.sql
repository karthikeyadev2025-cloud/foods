-- ============================================================
-- JYOTHI FOODS ERP — 74: SETTLE THE THREE FUNCTIONS THAT GREW
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
-- This file is the one to run LAST, after everything else.
--
-- WHY THIS EXISTS. Three things gained columns across db/71, db/72 and db/73,
-- each file adding to what the one before it wrote:
--
--   staff_list()      13 columns → 15 (the role name) → 18 (the pay terms)
--   save_staff()      the role row, then the pay terms
--   snapshot_tables() 'roles' at the front, then the payroll tables
--
-- Run in order that is correct. Run out of order — or a file re-run "to be
-- safe" — and the earlier version wins, because Postgres keeps whichever
-- definition ran last. The one that announces itself is staff_list, which
-- refuses outright:
--
--   ERROR: 42P13: cannot change return type of existing function
--   HINT:  Use DROP FUNCTION staff_list() first.
--
-- db/71 creates staff_list for the first time and so has no DROP in front of
-- it, which is what makes it unsafe to run late. The other two fail silently
-- instead, which is worse: save_staff quietly stops saving the pay terms, and
-- snapshot_tables quietly stops backing up the payroll tables. Nothing says so.
--
-- Rather than ask anybody to get the order right a second time, this file
-- states the final version of all three. Running it last settles them whatever
-- happened before — and running it twice is harmless, which is the point.
--
-- It adds nothing new. Every line is the db/73 version of something.
-- ============================================================

-- ------------------------------------------------------------
-- 1. staff_list — the users screen, with the pay terms
-- ------------------------------------------------------------
-- The wage figures are masked here, not in the grant: daily_wage is out of
-- the table's SELECT grant altogether (db/71), and monthly_salary and ot_rate
-- were never in it, because that grant names the columns it allows rather
-- than the ones it forbids.
drop function if exists staff_list();
create or replace function staff_list()
returns table (id uuid, org_id uuid, auth_uid uuid, full_name text, phone text, role staff_role,
               daily_wage numeric, is_mestry boolean, is_active boolean, created_at timestamptz,
               punchly_user_id text, punchly_staff_id text, designation text,
               role_id uuid, role_name text,
               pay_type text, monthly_salary numeric, ot_rate numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_wages boolean := can_view('attendance') or can_view('setup');
begin
  if my_org_id() is null then return; end if;
  return query
    select s.id, s.org_id, s.auth_uid, s.full_name, s.phone, s.role,
           case when v_wages then s.daily_wage end,
           s.is_mestry, s.is_active, s.created_at,
           s.punchly_user_id, s.punchly_staff_id, s.designation,
           s.role_id, r.name,
           s.pay_type,
           case when v_wages then s.monthly_salary end,
           case when v_wages then s.ot_rate end
      from staff s
      left join roles r on r.id = s.role_id
     where s.org_id = my_org_id()
     order by s.full_name;
end $$;

grant execute on function staff_list() to authenticated;

-- ------------------------------------------------------------
-- 2. save_staff — the role row and the pay terms
-- ------------------------------------------------------------
create or replace function save_staff(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p->>'id', '')::uuid;
        v_role_id uuid := nullif(p->>'role_id', '')::uuid; v_role staff_role; r roles%rowtype;
        v_pay text := nullif(p->>'pay_type', '');
begin
  if v_org is null then raise exception 'Organisation not known'; end if;
  if not has_role('owner', 'admin') then raise exception 'Only an owner or admin can change staff'; end if;
  if v_pay is not null and v_pay not in ('daily', 'monthly') then
    raise exception 'Somebody is paid by the day or on a monthly salary, not %', v_pay;
  end if;

  if v_role_id is not null then
    select * into r from roles where id = v_role_id and org_id = v_org;
    if not found then raise exception 'Role not found'; end if;
    v_role := r.based_on;
  else
    v_role := coalesce(nullif(p->>'role', '')::staff_role, 'sales_exec');
  end if;
  -- An admin may not make somebody an owner or a manager, exactly as
  -- create-user and set_staff_role refuse it.
  if my_role() = 'admin' and v_role in ('owner', 'admin') then
    raise exception 'An admin cannot make somebody an owner or a manager';
  end if;

  if v_id is null then
    insert into staff (org_id, full_name, phone, role, role_id, daily_wage, is_mestry, is_active, designation,
                       pay_type, monthly_salary, ot_rate)
    values (v_org, nullif(trim(p->>'full_name'), ''), nullif(trim(p->>'phone'), ''), v_role, v_role_id,
            coalesce(nullif(p->>'daily_wage', '')::numeric, 0),
            coalesce((p->>'is_mestry')::boolean, false),
            coalesce((p->>'is_active')::boolean, true),
            nullif(trim(p->>'designation'), ''),
            coalesce(v_pay, 'daily'),
            coalesce(nullif(p->>'monthly_salary', '')::numeric, 0),
            nullif(p->>'ot_rate', '')::numeric)
    returning id into v_id;
    return v_id;
  end if;

  update staff set
    full_name      = coalesce(nullif(trim(p->>'full_name'), ''), full_name),
    phone          = case when p ? 'phone' then nullif(trim(p->>'phone'), '') else phone end,
    role_id        = case when v_role_id is not null then v_role_id else role_id end,
    role           = case when p ? 'role' or v_role_id is not null then v_role else role end,
    daily_wage     = case when p ? 'daily_wage' then coalesce(nullif(p->>'daily_wage', '')::numeric, 0) else daily_wage end,
    is_mestry      = case when p ? 'is_mestry' then coalesce((p->>'is_mestry')::boolean, false) else is_mestry end,
    is_active      = case when p ? 'is_active' then coalesce((p->>'is_active')::boolean, true) else is_active end,
    designation    = case when p ? 'designation' then nullif(trim(p->>'designation'), '') else designation end,
    pay_type       = coalesce(v_pay, pay_type),
    monthly_salary = case when p ? 'monthly_salary' then coalesce(nullif(p->>'monthly_salary', '')::numeric, 0) else monthly_salary end,
    -- ot_rate is nullable on purpose — null means "work it out" — so it is
    -- asked whether the key is present rather than coalesced.
    ot_rate        = case when p ? 'ot_rate' then nullif(p->>'ot_rate', '')::numeric else ot_rate end
   where id = v_id and org_id = v_org;
  if not found then raise exception 'Staff member not found'; end if;
  return v_id;
end $$;

grant execute on function save_staff(jsonb) to authenticated;

-- ------------------------------------------------------------
-- 3. snapshot_tables — roles first, the payroll tables before attendance
-- ------------------------------------------------------------
-- Built from the list rather than typed again: whatever the current definition
-- says, this puts 'roles' at the front (staff.role_id and
-- role_permissions.role_id point at it), the three payroll masters immediately
-- before 'attendance' (which references the leave kinds), and the wage run at
-- the end. Every name appears exactly once however many times this is run.
do $$
declare v_list text[]; v_out text[] := '{}'; t text;
begin
  select snapshot_tables() into v_list;

  -- drop the ones this file is about to place, wherever they are now
  foreach t in array v_list loop
    if split_part(t, ':', 1) = any (array['roles', 'leave_types', 'holidays', 'staff_advances',
                                          'wage_payments', 'wage_payment_lines']) then
      continue;
    end if;
    v_out := v_out || t;
  end loop;

  -- and place them
  v_list := array['roles'];
  foreach t in array v_out loop
    if split_part(t, ':', 1) = 'attendance' then
      v_list := v_list || array['leave_types', 'holidays', 'staff_advances'];
    end if;
    v_list := v_list || t;
  end loop;
  v_list := v_list || array['wage_payments', 'wage_payment_lines:run_id:wage_payments'];

  execute format(
    'create or replace function snapshot_tables() returns text[] language sql immutable as $f$ select %L::text[] $f$',
    v_list);
end $$;

-- ------------------------------------------------------------
-- 4. And say what the state is, so it can be read rather than assumed
-- ------------------------------------------------------------
do $$
declare v_cols int; v_snap text[];
begin
  -- A function's result columns are its OUT parameters, not an entry in
  -- information_schema.columns — which is empty for a function and would
  -- cheerfully report zero.
  select count(*) into v_cols
    from pg_proc p, unnest(p.proargmodes) m
   where p.oid = 'staff_list()'::regprocedure and m = 't';
  select snapshot_tables() into v_snap;
  raise notice 'staff_list has % columns (18 is right); snapshot covers % tables, roles is #%, attendance is #%',
    v_cols, array_length(v_snap, 1),
    array_position(v_snap, 'roles'), array_position(v_snap, 'attendance');
end $$;
