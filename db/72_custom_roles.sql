-- ============================================================
-- JYOTHI FOODS ERP — 72: THE SHOP NAMES ITS OWN JOBS
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- Until now there were eight roles and no ninth: staff_role is a Postgres
-- enum, and "Packing in-charge", "Night godown" and "Supervisor" could not
-- exist. Every shop had to pretend its people were one of our eight.
--
-- Now the shop makes its own. A role is a row: a name the shop chose, and the
-- built-in role it is BASED ON.
--
-- WHY "BASED ON" AND NOT A CLEAN SLATE. Two kinds of right live in this
-- database and only one of them is in the permission matrix:
--
--   * Module rights — may this job see Purchases, edit Invoices, delete
--     Receipts. Rows in role_permissions, edited in Setup, and read by every
--     RLS policy through can_view() / can_edit() / can_delete(). These are
--     the shop's to decide, per role, and that is what this file opens up.
--
--   * Hard-wired rights — things the code asks about by name:
--     `my_role() = 'owner'` for the licence, the backup and the master reset;
--     `has_role('owner','admin')` for creating logins. Eleven places say
--     <> 'owner', nine say = 'owner', six say 'chief'. A role with no
--     built-in behind it would have to answer those questions somehow, and
--     the only honest answers are "like an owner", "like an admin", "like a
--     chief" — which is what based_on IS.
--
-- So based_on decides the handful of hard-wired rights, and the matrix decides
-- everything else. The shop can have fifteen roles, each named for a real job
-- in the factory, each with its own tick boxes.
--
-- HOW THIS DOES NOT BREAK THE OTHER SEVENTY FILES. my_role() still returns a
-- staff_role and still reads staff.role — not one policy, function or test
-- changes. A trigger keeps staff.role equal to the based_on of whatever role
-- the person holds, so the enum stays true and the custom name rides alongside
-- it. The matrix is looked up by role_id instead of by the enum, which is the
-- one change, and a fallback keeps the enum path working for any row that
-- somehow has no role_id.
--
-- An admin cannot promote himself. A custom role may never be based on the
-- owner — there is one owner — and an admin may neither create nor hand out a
-- role based on owner or admin, exactly as create-user has always refused it.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The roles themselves
-- ------------------------------------------------------------
create table if not exists roles (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  -- what the shop calls this job
  name        text not null,
  -- the built-in role whose hard-wired rights it inherits
  based_on    staff_role not null,
  -- the original eight: renameable, never deletable, one per based_on
  is_system   boolean not null default false,
  sort_order  integer not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- Two jobs with the same name in one shop is a mistake, not a choice.
create unique index if not exists roles_name_key on roles (org_id, lower(name));
-- Exactly one system role per built-in, so the backfill and the defaults have
-- something unambiguous to point at.
create unique index if not exists roles_system_key on roles (org_id, based_on) where is_system;
create index if not exists roles_org_idx on roles (org_id, sort_order, name);

alter table roles enable row level security;
drop policy if exists roles_read on roles;
-- Everyone signed in reads the names: a screen that shows who entered a bill
-- shows their job title, and the login screen's own role has to be nameable.
create policy roles_read on roles for select using (org_id = my_org_id());
-- No write policy: roles are created and changed through save_role() /
-- delete_role() below, which are owner-only and check the escalation rules.

grant select on roles to authenticated;

-- ------------------------------------------------------------
-- 2. The eight built-ins become rows, for every shop that exists
-- ------------------------------------------------------------
/** The name a shop sees for a built-in role before it renames it. */
create or replace function builtin_role_label(p_role staff_role) returns text
language sql immutable as $$
  select case p_role
    when 'owner'           then 'Owner'
    when 'admin'           then 'Manager'
    when 'accountant'      then 'Accountant'
    when 'store_keeper'    then 'Store keeper'
    when 'production_head' then 'Production head'
    when 'chief'           then 'Chief'
    when 'driver'          then 'Driver'
    when 'sales_exec'      then 'Sales / counter'
  end;
$$;

/** Give an org the eight system roles if it has not got them. Idempotent. */
create or replace function seed_system_roles(p_org uuid) returns void
language sql as $$
  insert into roles (org_id, name, based_on, is_system, sort_order)
  select p_org, builtin_role_label(r.role), r.role, true,
         (array_position(enum_range(null::staff_role), r.role)) * 10
    from unnest(enum_range(null::staff_role)) as r(role)
   where not exists (select 1 from roles x
                      where x.org_id = p_org and x.is_system and x.based_on = r.role)
     -- A shop may have renamed a built-in; only the missing ones are added,
     -- and lower(name) is unique, so a clash is skipped rather than failing.
     and not exists (select 1 from roles x
                      where x.org_id = p_org and lower(x.name) = lower(builtin_role_label(r.role)));
$$;

do $$
declare o record;
begin
  for o in select id from orgs loop
    perform seed_system_roles(o.id);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 3. A person holds a role row, and the enum follows it
-- ------------------------------------------------------------
-- ON DELETE SET NULL, not restrict: a master reset and a restore clear the
-- tables in order, and roles goes before staff. A staff row left pointing at
-- nothing still works — my_role() reads the enum, and can_view() falls back to
-- the system role for that enum — and the trigger below ties it to a role row
-- again the next time the person is saved.
alter table staff add column if not exists role_id uuid references roles(id) on delete set null;
create index if not exists staff_role_id_idx on staff(role_id);

-- A column added by an earlier run of this file would carry the stricter rule,
-- so the constraint is restated either way.
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'staff'::regclass and contype = 'f'
     and confrelid = 'roles'::regclass
     and confdeltype <> 'n';
  if c is not null then
    execute format('alter table staff drop constraint %I', c);
    execute 'alter table staff add constraint staff_role_id_fkey foreign key (role_id) references roles(id) on delete set null';
  end if;
end $$;

update staff s
   set role_id = r.id
  from roles r
 where r.org_id = s.org_id and r.is_system and r.based_on = s.role
   and s.role_id is null;

/**
 * Keep the enum and the role row saying the same thing, whichever one was set.
 *
 * This is what lets seventy files carry on asking `my_role() = 'owner'`
 * without knowing custom roles exist. Set role_id and the enum follows from
 * its based_on; set only the enum — which every older insert path does,
 * create-user included — and the matching system role is filled in.
 */
create or replace function trg_staff_role_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare r roles%rowtype; v_follow_role_id boolean;
begin
  -- WHICH of the two was just set decides which one follows. Getting this
  -- wrong is silent and nasty: a plain `update staff set role = 'admin'` —
  -- which the users screen has always done and which several tests do — would
  -- be undone on the way in if role_id always won, and the person would stay
  -- exactly as they were with the screen showing success.
  if tg_op = 'UPDATE' then
    if new.role_id is distinct from old.role_id and new.role_id is not null then
      v_follow_role_id := true;        -- a role row was chosen: the enum follows it
    elsif new.role is distinct from old.role then
      v_follow_role_id := false;       -- a built-in was chosen: the role row follows
    elsif new.role_id is null and old.role_id is not null then
      -- role_id was cleared rather than changed — a deleted role setting it
      -- null through the foreign key. The enum is the truth then, and the
      -- person is tied back to the matching system role if there is one.
      v_follow_role_id := false;
    else
      return new;                      -- neither changed
    end if;
  else
    v_follow_role_id := new.role_id is not null;
  end if;

  if v_follow_role_id then
    select * into r from roles where id = new.role_id;
    if not found then raise exception 'Role not found'; end if;
    if r.org_id <> new.org_id then
      raise exception 'That role belongs to another organisation';
    end if;
    new.role := r.based_on;
  else
    select * into r from roles
     where org_id = new.org_id and is_system and based_on = new.role;
    -- A brand new org inserts its owner before seed_system_roles has run, so
    -- a missing row is not an error: the enum alone still works, and the
    -- backfill or the next save picks it up.
    new.role_id := case when found then r.id else null end;
  end if;
  return new;
end $$;

drop trigger if exists staff_role_sync on staff;
create trigger staff_role_sync before insert or update of role, role_id on staff
  for each row execute function trg_staff_role_sync();

/** The role row the signed-in person holds. */
create or replace function my_role_id() returns uuid
language sql stable security definer set search_path = public as $$
  select role_id from staff where auth_uid = auth.uid() and is_active limit 1;
$$;

grant execute on function my_role_id() to authenticated;

-- my_role() is deliberately NOT changed. It still reads staff.role, which the
-- trigger above keeps equal to the based_on of whatever role the person holds,
-- so every hard-wired check in every other file keeps its meaning and its
-- speed.

-- ------------------------------------------------------------
-- 4. The matrix hangs off the role row
-- ------------------------------------------------------------
alter table role_permissions add column if not exists role_id uuid references roles(id) on delete cascade;

update role_permissions rp
   set role_id = r.id
  from roles r
 where r.org_id = rp.org_id and r.is_system and r.based_on = rp.role
   and rp.role_id is null;

-- The old constraint said one row per (org, enum role, module), which is
-- exactly what stops two custom roles that are both based on sales_exec from
-- having different rights. It goes; the role row is the key now.
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'role_permissions'::regclass and contype = 'u' loop
    execute format('alter table role_permissions drop constraint %I', c);
  end loop;
end $$;

delete from role_permissions where role_id is null;
alter table role_permissions alter column role_id set not null;
create unique index if not exists role_permissions_key on role_permissions (role_id, module);

/**
 * The default tick boxes for a role, taken from the built-in it is based on.
 *
 * This is the matrix from db/27 with one change: it is addressed by role_id,
 * so it can be used both to set a new shop up and to fill in a role the shop
 * has just invented. Only missing rows are written, so running it again never
 * undoes a shop's own edits.
 */
create or replace function seed_role_defaults(p_role uuid) returns void
language sql as $$
  insert into role_permissions (org_id, role, role_id, module, can_view, can_edit, can_delete)
  select r.org_id, r.based_on, r.id, m.module,
         case when r.based_on = 'owner' then true
              when r.based_on = 'admin' then true
              when r.based_on = 'accountant'      then m.module in ('dashboard','customers','items','invoices','returns','receipts','payments','stock','reports','vehicles','attendance')
              when r.based_on = 'store_keeper'    then m.module in ('dashboard','items','purchases','stock','vehicles','reports')
              when r.based_on = 'production_head' then m.module in ('dashboard','items','stock','production','reports')
              when r.based_on = 'chief'           then m.module in ('dashboard','production')
              when r.based_on = 'driver'          then m.module in ('dashboard','invoices','receipts','vehicles')
              when r.based_on = 'sales_exec'      then m.module in ('dashboard','customers','items','invoices','returns','receipts','stock')
              else false end,
         case when r.based_on in ('owner','admin') then true
              when r.based_on = 'accountant'      then m.module in ('customers','invoices','returns','receipts','payments','attendance')
              when r.based_on = 'store_keeper'    then m.module in ('items','purchases','stock','vehicles')
              when r.based_on = 'production_head' then m.module in ('production')
              when r.based_on = 'chief'           then m.module in ('production')
              when r.based_on = 'driver'          then m.module in ('invoices','receipts')
              when r.based_on = 'sales_exec'      then m.module in ('customers','invoices','receipts')
              else false end,
         case when r.based_on = 'owner' then true
              when r.based_on = 'admin' then m.module <> 'setup'
              else false end
    from roles r
    cross join unnest(array['dashboard','items','customers','invoices','purchases','returns','receipts',
                            'payments','stock','production','vehicles','messaging','reports','setup','attendance']) as m(module)
   where r.id = p_role
  on conflict (role_id, module) do nothing;
$$;

/** Set a whole shop up: the eight roles, then the default rights for each. */
create or replace function seed_role_permissions(p_org uuid) returns void
language plpgsql as $$
declare r record;
begin
  perform seed_system_roles(p_org);
  for r in select id from roles where org_id = p_org loop
    perform seed_role_defaults(r.id);
  end loop;
  -- Any staff row inserted before the roles existed (the owner of a brand new
  -- org) is tied to its role now.
  update staff s set role_id = x.id
    from roles x
   where x.org_id = s.org_id and x.is_system and x.based_on = s.role
     and s.org_id = p_org and s.role_id is null;
end $$;

-- Every org that already existed: fill in the rows for its new role ids.
do $$
declare o record;
begin
  for o in select id from orgs loop
    perform seed_role_permissions(o.id);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 5. Asking the matrix
-- ------------------------------------------------------------
-- By role row first. The enum fallback is for a staff row that somehow has no
-- role_id — a brand new org mid-bootstrap, or a restored backup taken before
-- this file — and costs nothing when role_id is there.
--
-- The licence comes first in all three, as db/21 made it: a module the plan
-- does not include is shut whatever the shop ticks, and a tick box the shop
-- set years ago must not quietly reopen a capped feature.
create or replace function can_view(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_feature(module_feature(p_module)) and case
    when my_role() = 'owner' then true
    else coalesce(
      (select rp.can_view from role_permissions rp
        where rp.role_id = my_role_id() and rp.module = p_module),
      (select rp.can_view from role_permissions rp
        join roles r on r.id = rp.role_id
        where r.org_id = my_org_id() and r.is_system and r.based_on = my_role()
          and rp.module = p_module),
      false)
  end;
$$;

create or replace function can_edit(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_feature(module_feature(p_module)) and case
    when my_role() = 'owner' then true
    else coalesce(
      (select rp.can_edit from role_permissions rp
        where rp.role_id = my_role_id() and rp.module = p_module),
      (select rp.can_edit from role_permissions rp
        join roles r on r.id = rp.role_id
        where r.org_id = my_org_id() and r.is_system and r.based_on = my_role()
          and rp.module = p_module),
      false)
  end;
$$;

create or replace function can_delete(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_feature(module_feature(p_module)) and case
    when my_role() = 'owner' then true
    else coalesce(
      (select rp.can_delete from role_permissions rp
        where rp.role_id = my_role_id() and rp.module = p_module),
      (select rp.can_delete from role_permissions rp
        join roles r on r.id = rp.role_id
        where r.org_id = my_org_id() and r.is_system and r.based_on = my_role()
          and rp.module = p_module),
      false)
  end;
$$;

-- ------------------------------------------------------------
-- 6. Making, renaming and removing a role
-- ------------------------------------------------------------
/**
 * Create or rename a role. The owner only.
 *
 * Not an admin, and this is the whole point of the restriction: an admin who
 * could invent a role, base it on owner and give it to himself would be the
 * owner by teatime. So a custom role may never be based on owner, an admin may
 * not do this at all, and the hard-wired rights of a role can never be changed
 * after it is created — only its name, its order and whether it is in use.
 */
create or replace function save_role(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p->>'id', '')::uuid;
        v_name text := nullif(trim(p->>'name'), ''); v_based staff_role; r roles%rowtype;
begin
  if v_org is null then raise exception 'Organisation not known'; end if;
  if my_role() <> 'owner' then raise exception 'Only the owner can add or rename a job role'; end if;
  if v_name is null then raise exception 'The role needs a name'; end if;

  if v_id is null then
    v_based := coalesce(nullif(p->>'based_on', '')::staff_role, 'sales_exec');
    if v_based = 'owner' then
      raise exception 'A role cannot be based on Owner — there is one owner. Base it on Manager for someone who runs the shop.';
    end if;
    insert into roles (org_id, name, based_on, is_system, sort_order, is_active)
    values (v_org, v_name, v_based, false,
            coalesce(nullif(p->>'sort_order', '')::integer, 100),
            coalesce((p->>'is_active')::boolean, true))
    returning id into v_id;
    -- A new role starts from the built-in's defaults rather than from nothing,
    -- so the owner edits a sensible set instead of ticking forty boxes.
    perform seed_role_defaults(v_id);
    return v_id;
  end if;

  select * into r from roles where id = v_id and org_id = v_org;
  if not found then raise exception 'Role not found'; end if;
  -- based_on is deliberately not updatable: changing it would silently move
  -- people between hard-wired rights.
  update roles set
    name       = v_name,
    sort_order = coalesce(nullif(p->>'sort_order', '')::integer, sort_order),
    is_active  = coalesce((p->>'is_active')::boolean, is_active)
   where id = v_id;
  return v_id;
end $$;

/** Remove a role. Never a built-in, and never one somebody still holds. */
create or replace function delete_role(p_role uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r roles%rowtype; n integer;
begin
  if my_role() <> 'owner' then raise exception 'Only the owner can remove a job role'; end if;
  select * into r from roles where id = p_role and org_id = my_org_id();
  if not found then raise exception 'Role not found'; end if;
  if r.is_system then
    raise exception '% is one of the built-in roles. It can be renamed but not removed.', r.name;
  end if;
  select count(*) into n from staff where role_id = p_role and is_active;
  if n > 0 then
    raise exception '% people still have this role. Move them to another role first.', n;
  end if;
  delete from roles where id = p_role;   -- its permission rows go with it
end $$;

/** Put a person in a role. Owner or admin, with the escalation rule. */
create or replace function set_staff_role(p_staff uuid, p_role uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r roles%rowtype;
begin
  if not has_role('owner', 'admin') then raise exception 'Only an owner or admin can change somebody''s role'; end if;
  select * into r from roles where id = p_role and org_id = my_org_id();
  if not found then raise exception 'Role not found'; end if;
  if my_role() = 'admin' and r.based_on in ('owner', 'admin') then
    raise exception 'An admin cannot make somebody an owner or a manager';
  end if;
  if not exists (select 1 from staff where id = p_staff and org_id = my_org_id()) then
    raise exception 'Staff member not found';
  end if;
  -- The trigger sets staff.role from the role's based_on.
  update staff set role_id = p_role where id = p_staff;
end $$;

grant execute on function save_role(jsonb) to authenticated;
grant execute on function delete_role(uuid) to authenticated;
grant execute on function set_staff_role(uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- 7. What the screens read
-- ------------------------------------------------------------
/** Every role in the shop, with how many people hold it. */
create or replace function role_list()
returns table (id uuid, name text, based_on staff_role, is_system boolean, sort_order integer,
               is_active boolean, staff_count integer)
language sql stable security definer set search_path = public as $$
  select r.id, r.name, r.based_on, r.is_system, r.sort_order, r.is_active,
         (select count(*)::integer from staff s where s.role_id = r.id and s.is_active)
    from roles r
   where r.org_id = my_org_id()
   order by r.sort_order, r.name;
$$;

grant execute on function role_list() to authenticated;

-- staff_list() gains the role name, so the users screen shows the shop's own
-- job titles rather than our eight. Unlike a view, a function's result
-- columns cannot be appended in place — the return type is part of its
-- identity — so it is dropped and written again.
drop function if exists staff_list();
create or replace function staff_list()
returns table (id uuid, org_id uuid, auth_uid uuid, full_name text, phone text, role staff_role,
               daily_wage numeric, is_mestry boolean, is_active boolean, created_at timestamptz,
               punchly_user_id text, punchly_staff_id text, designation text,
               role_id uuid, role_name text)
language plpgsql stable security definer set search_path = public as $$
declare v_wages boolean := can_view('attendance') or can_view('setup');
begin
  if my_org_id() is null then return; end if;
  return query
    select s.id, s.org_id, s.auth_uid, s.full_name, s.phone, s.role,
           case when v_wages then s.daily_wage end,
           s.is_mestry, s.is_active, s.created_at,
           s.punchly_user_id, s.punchly_staff_id, s.designation,
           s.role_id, r.name
      from staff s
      left join roles r on r.id = s.role_id
     where s.org_id = my_org_id()
     order by s.full_name;
end $$;

grant execute on function staff_list() to authenticated;

-- save_staff takes a role_id as well, so one call adds a person in a custom
-- role. The escalation rule is the same one set_staff_role applies.
create or replace function save_staff(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p->>'id', '')::uuid;
        v_role_id uuid := nullif(p->>'role_id', '')::uuid; v_role staff_role; r roles%rowtype;
begin
  if v_org is null then raise exception 'Organisation not known'; end if;
  if not has_role('owner', 'admin') then raise exception 'Only an owner or admin can change staff'; end if;

  if v_role_id is not null then
    select * into r from roles where id = v_role_id and org_id = v_org;
    if not found then raise exception 'Role not found'; end if;
    v_role := r.based_on;
  else
    v_role := coalesce(nullif(p->>'role', '')::staff_role, 'sales_exec');
  end if;
  if my_role() = 'admin' and v_role in ('owner', 'admin') then
    raise exception 'An admin cannot make somebody an owner or a manager';
  end if;

  if v_id is null then
    insert into staff (org_id, full_name, phone, role, role_id, daily_wage, is_mestry, is_active, designation)
    values (v_org, nullif(trim(p->>'full_name'), ''), nullif(trim(p->>'phone'), ''), v_role, v_role_id,
            coalesce(nullif(p->>'daily_wage', '')::numeric, 0),
            coalesce((p->>'is_mestry')::boolean, false),
            coalesce((p->>'is_active')::boolean, true),
            nullif(trim(p->>'designation'), ''))
    returning id into v_id;
    return v_id;
  end if;

  update staff set
    full_name   = coalesce(nullif(trim(p->>'full_name'), ''), full_name),
    phone       = case when p ? 'phone' then nullif(trim(p->>'phone'), '') else phone end,
    role_id     = case when v_role_id is not null then v_role_id else role_id end,
    role        = case when p ? 'role' or v_role_id is not null then v_role else role end,
    daily_wage  = case when p ? 'daily_wage' then coalesce(nullif(p->>'daily_wage', '')::numeric, 0) else daily_wage end,
    is_mestry   = case when p ? 'is_mestry' then coalesce((p->>'is_mestry')::boolean, false) else is_mestry end,
    is_active   = case when p ? 'is_active' then coalesce((p->>'is_active')::boolean, true) else is_active end,
    designation = case when p ? 'designation' then nullif(trim(p->>'designation'), '') else designation end
   where id = v_id and org_id = v_org;
  if not found then raise exception 'Staff member not found'; end if;
  return v_id;
end $$;

grant execute on function save_staff(jsonb) to authenticated;

-- ------------------------------------------------------------
-- 8. The roles go in the backup
-- ------------------------------------------------------------
-- roles has to be restored BEFORE staff, or staff.role_id points at nothing.
-- snapshot_tables() is written in order and org_snapshot walks it in order,
-- so roles is inserted ahead of the rest rather than appended.
-- The whole list again with 'roles' at the front, because org_snapshot() and
-- the restore both walk it in order and staff.role_id and
-- role_permissions.role_id point at it. Spelled out rather than computed: a
-- function cannot prepend to its own result, and the restore order is the one
-- thing in a backup that must not be clever.
create or replace function snapshot_tables() returns text[]
language sql immutable as $$
  select array[
    'roles', 'uoms', 'pack_types', 'item_categories', 'sections', 'items', 'item_price_overrides',
    'price_lists', 'price_list_items:price_list_id:price_lists', 'discount_schemes', 'item_barcodes', 'routes',
    'customers', 'suppliers', 'stock_locations', 'vehicles', 'expense_heads', 'cash_bank_accounts',
    'receipt_modes', 'number_series', 'role_permissions', 'ledger_accounts', 'recipes',
    'recipe_ingredients:recipe_id:recipes', 'production_batches',
    'batch_ingredients:batch_id:production_batches', 'item_batches', 'vehicle_trips', 'invoices',
    'invoice_items:invoice_id:invoices', 'inbound_orders', 'quotations',
    'quotation_items:quotation_id:quotations', 'orders', 'order_items:order_id:orders', 'order_fulfilments',
    'delivery_challans', 'challan_items:challan_id:delivery_challans', 'purchases',
    'purchase_items:purchase_id:purchases', 'purchase_returns',
    'purchase_return_items:return_id:purchase_returns', 'sales_returns',
    'sales_return_items:return_id:sales_returns', 'receipts', 'receipt_lines:receipt_id:receipts',
    'receipt_allocations:receipt_id:receipts', 'payments', 'cheques', 'account_transfers', 'stock_transfers',
    'stock_transfer_items:transfer_id:stock_transfers', 'stock_counts',
    'stock_count_items:count_id:stock_counts', 'stock_ledger', 'journal_entries',
    'journal_lines:entry_id:journal_entries', 'account_transactions', 'message_templates', 'reminder_rules',
    'catalogs', 'broadcasts', 'new_stock_rules', 'message_log', 'transaction_message_settings',
    'messaging_settings', 'punchly_settings', 'print_templates', 'attendance', 'staff'
  ];
$$;

-- ------------------------------------------------------------
-- 9. A restore keeps the roles, the way it keeps the logins
-- ------------------------------------------------------------
-- The restore clears each table and puts the snapshot's rows back. Clearing
-- `roles` sets every staff member's role_id to null on the way through, and
-- staff is deliberately NOT restored — logins are live state, kept as they
-- are — so the assignments would be lost and never come back.
--
-- So roles joins staff and messaging_settings on the skip list: live state,
-- kept rather than overwritten. It stays in snapshot_tables() so a backup
-- FILE still carries the shop's own job titles, which is what makes a rebuild
-- from a file into a fresh organisation possible; it is only this in-place
-- restore that leaves them alone. Everything else in the function is db/17's,
-- unchanged.
CREATE OR REPLACE FUNCTION public.restore_org_snapshot(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; spec text; parts text[]; t text; specs text[]; i int; n int; v_counts jsonb := '{}'::jsonb; v_rows jsonb; v_cols text;
        skip text[] := array['staff', 'messaging_settings', 'roles'];
begin
  if not is_service_call() and my_role() <> 'owner' then raise exception 'Only the owner can restore'; end if;
  v_org := (p->>'org_id')::uuid;
  if v_org is null or jsonb_typeof(p->'tables') <> 'object' then raise exception 'Not a backup file'; end if;
  if not is_service_call() and v_org is distinct from my_org_id() then raise exception 'This backup belongs to another organisation'; end if;
  specs := snapshot_tables();

  -- triggers off on every table so restored rows are copied, not re-posted
  foreach spec in array specs loop
    t := (string_to_array(spec, ':'))[1];
    if t = any(skip) then continue; end if;
    execute format('alter table %I disable trigger user', t);
  end loop;

  -- delete: dependents first
  for i in reverse array_length(specs, 1)..1 loop
    parts := string_to_array(specs[i], ':');
    t := parts[1];
    if t = any(skip) then continue; end if;
    if array_length(parts, 1) = 3 then
      execute format('delete from %I where %I in (select id from %I where org_id = $1)', t, parts[2], parts[3]) using v_org;
    else
      execute format('delete from %I where org_id = $1', t) using v_org;
    end if;
  end loop;

  -- insert: parents first
  foreach spec in array specs loop
    parts := string_to_array(spec, ':');
    t := parts[1];
    if t = any(skip) then continue; end if;
    v_rows := p->'tables'->t;
    if v_rows is null or jsonb_typeof(v_rows) <> 'array' then continue; end if;
    -- generated columns are recomputed, everything else is copied as it was
    select string_agg(format('%I', c.column_name), ', ' order by c.ordinal_position) into v_cols
      from information_schema.columns c
     where c.table_schema = 'public' and c.table_name = t and c.is_generated = 'NEVER' and coalesce(c.identity_generation, '') <> 'ALWAYS';
    execute format('insert into %I (%s) select %s from jsonb_populate_recordset(null::%I, $1)', t, v_cols, v_cols, t) using v_rows;
    get diagnostics n = row_count;
    v_counts := v_counts || jsonb_build_object(t, n);
  end loop;

  foreach spec in array specs loop
    t := (string_to_array(spec, ':'))[1];
    if t = any(skip) then continue; end if;
    execute format('alter table %I enable trigger user', t);
  end loop;

  -- the org row itself (profile and terms), never the licence
  if jsonb_typeof(p->'org') = 'object' then
    update orgs o set name = coalesce(p->'org'->>'name', o.name), address = p->'org'->>'address', phone = p->'org'->>'phone', fssai_no = p->'org'->>'fssai_no',
           breakage_recovery_pct = coalesce((p->'org'->>'breakage_recovery_pct')::numeric, o.breakage_recovery_pct),
           interest_pct_pa = coalesce((p->'org'->>'interest_pct_pa')::numeric, o.interest_pct_pa),
           credit_days = coalesce((p->'org'->>'credit_days')::int, o.credit_days), jurisdiction = p->'org'->>'jurisdiction',
           logo_url = p->'org'->>'logo_url', signature_url = p->'org'->>'signature_url', email = p->'org'->>'email', tagline = p->'org'->>'tagline', bank_details = p->'org'->>'bank_details'
     where o.id = v_org;
  end if;

  -- serial ids came back with the rows; move the sequences past them
  perform setval('stock_ledger_id_seq', greatest((select coalesce(max(id), 0) from stock_ledger), 1));
  perform setval('journal_lines_id_seq', greatest((select coalesce(max(id), 0) from journal_lines), 1));
  perform setval('account_transactions_id_seq', greatest((select coalesce(max(id), 0) from account_transactions), 1));

  insert into audit_log (org_id, actor, action, table_name, row_id, after)
  values (v_org, my_staff_id(), 'RESTORE', 'orgs', v_org::text, jsonb_build_object('taken_at', p->>'taken_at', 'tables', v_counts));
  return jsonb_build_object('org_id', v_org, 'restored', v_counts, 'taken_at', p->>'taken_at');
end $function$;

-- ------------------------------------------------------------
-- 10. A master reset keeps the roles too
-- ------------------------------------------------------------
-- reset_keeps() is written as what to KEEP, so a table added later is cleared
-- by default — which is the safe way round, and it means roles has to be named
-- or a reset takes the shop's job titles with it. Worse than losing the names:
-- role_permissions cascades off roles, so the whole permission matrix would go
-- and nobody but the owner could do anything.
--
-- 'staff' and 'role_permissions' were already kept in all three scopes, for
-- the same reason. roles joins them. Everything else is db/52's list unchanged.
create or replace function reset_keeps(p_scope text) returns text[]
language sql immutable as $$
  select case p_scope
    when 'transactions' then array[
      'uoms','pack_types','item_categories','sections','items','item_price_overrides',
      'price_lists','price_list_items','discount_schemes','item_barcodes','routes',
      'customers','suppliers','stock_locations','vehicles','expense_heads',
      'cash_bank_accounts','receipt_modes','number_series','roles','role_permissions',
      'ledger_accounts','recipes','recipe_ingredients',
      'message_templates','reminder_rules','catalogs','new_stock_rules',
      'transaction_message_settings','messaging_settings','print_templates','staff']
    when 'masters' then array[
      'uoms','pack_types','sections','stock_locations','expense_heads',
      'cash_bank_accounts','receipt_modes','number_series','roles','role_permissions',
      'ledger_accounts',
      'message_templates','reminder_rules','catalogs','new_stock_rules',
      'transaction_message_settings','messaging_settings','print_templates','staff']
    when 'everything' then array[
      'ledger_accounts','cash_bank_accounts',
      'number_series','roles','role_permissions',
      'transaction_message_settings','messaging_settings','print_templates','staff']
    else null end;
$$;

comment on table roles is
  'The jobs this shop has, named by the shop. based_on gives the built-in role whose hard-wired rights it inherits; the module tick boxes are its own (db/72).';
