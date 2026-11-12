-- ============================================================
-- JYOTHI FOODS ERP — 71: WHAT WE PAY, AND WHAT WE PAY PEOPLE
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- A counter boy signed in with the lowest role in the shop — no purchases
-- right, no payments right, no reports right — could read all of this:
--
--   select purchase_rate from items          →  62.00    (what we pay for it)
--   select * from v_item_profit              →  cost 3,100, profit 1,900
--   select full_name, daily_wage from staff  →  Owner = 18,000
--
-- None of it is a row he was not allowed to see. All of it is a COLUMN on a
-- row he was always allowed to see, and that is the hole. The module gates
-- answer "may this role read these rows", and masters — items, staff — were
-- deliberately left readable by everybody, because a biller needs item names
-- and sixteen screens show "entered by" against a staff name. Our buying
-- price and our wage bill happen to live on those two tables.
--
-- In this trade the purchase rate is the one figure that must never leave the
-- office: in a salesman's hands it is a competitor's price list. What each
-- person is paid is the other one.
--
-- Row-level security cannot help here — it decides rows, not columns, and
-- there is no way to say "null for this role". A view cannot help on its own
-- either, because the table stays readable through the API whatever the app
-- chooses to show. So this does the only thing that actually closes it:
--
--   * the two columns are taken out of the SELECT grant, so nobody signed in
--     can read them from the table, however they ask — the app, the console,
--     curl with a stolen token, all the same
--   * the figures come back through one security-definer function each, which
--     asks the module gate first, so the people whose job needs them still see
--     them and the answer is computed in one place instead of six
--   * every view that showed them reads that function, so the screens keep
--     working and a role without the right gets null instead of a number
--
-- Taking a column out of a grant means `select *` on that table stops working
-- for EVERYONE, owner included, so the few places that did are changed to name
-- their columns. That is the cost of this fix and it is cheap: `select *` was
-- never safe on a table with a column not everybody may read.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Who may see what a thing cost
-- ------------------------------------------------------------
/**
 * Cost is a purchases question and a production question, and nobody else's.
 *
 * The store keeper buys it and the production head mixes it, so both have to
 * know what it costs. The counter, the driver and the office boy do not — and
 * the owner, as everywhere, may see everything.
 *
 * One named function rather than the same `or` written out in four views, so
 * the rule can be changed in one place and this comment is the only place it
 * has to be explained.
 */
create or replace function can_see_cost() returns boolean
language sql stable security definer set search_path = public as $$
  select can_view('purchases') or can_view('production');
$$;

/** What we pay for an item, or null to anyone whose job does not involve it. */
create or replace function item_cost(p_item uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when can_see_cost()
              then (select i.purchase_rate from items i
                     where i.id = p_item and i.org_id = my_org_id())
         end;
$$;

/** What a staff member is paid. The wage sheet and the owner's own screens. */
create or replace function staff_wage(p_staff uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when can_view('attendance') or can_view('setup')
              then (select s.daily_wage from staff s
                     where s.id = p_staff and s.org_id = my_org_id())
         end;
$$;

grant execute on function can_see_cost() to authenticated;
grant execute on function item_cost(uuid) to authenticated;
grant execute on function staff_wage(uuid) to authenticated;

-- ------------------------------------------------------------
-- 2. The views stop reading the columns directly
-- ------------------------------------------------------------
-- These run as the person looking (security_invoker), so once the grant below
-- lands they would fail outright if they still touched the columns. Reading
-- the definer function instead is what turns "permission denied" into a blank
-- cell for a role without the right, and leaves the number there for one with
-- it. A view may only ever have columns appended, so each keeps its column
-- name and type and only changes what fills it.
create or replace view v_item_profit as
select i.org_id, i.id as item_id, i.item_code, i.name,
       coalesce(sum(ii.amount), 0) as sale_value,
       -- was sum(ii.qty_base * i.purchase_rate)
       case when can_see_cost() then coalesce(sum(ii.qty_base * item_cost(i.id)), 0) end as cost_value,
       case when can_see_cost() then coalesce(sum(ii.amount), 0) - coalesce(sum(ii.qty_base * item_cost(i.id)), 0) end as gross_profit
from items i
left join invoice_items ii on ii.item_id = i.id
left join invoices inv on inv.id = ii.invoice_id and inv.status <> 'cancelled'
group by i.org_id, i.id, i.item_code, i.name;

alter view v_item_profit set (security_invoker = on);

-- The item list the whole app reads. Its purchase_rate column stays, and is
-- filled by the function, so a store keeper sees the cost on the item screen
-- and a biller sees an empty cell instead of being refused the screen.
create or replace view v_item_list as
select i.id, i.org_id, i.item_code, i.name, i.type, i.is_active, i.created_at,
       i.pack_type_id, pt.code as pack_code,
       i.section_id, s.code as section_code, s.name as section_name,
       coalesce(s.sort_order, 999) as section_sort,
       i.base_uom_id, u.code as base_uom_code,
       i.units_per_box, i.pieces_per_unit, i.mrp_per_piece, i.net_weight_g,
       i.unit_rate, i.box_rate,
       item_cost(i.id)::numeric(12,2) as purchase_rate,   -- was i.purchase_rate
       i.reorder_level, i.shelf_life_days,
       exists (select 1 from stock_ledger sl where sl.item_id = i.id) as has_stock_movement,
       coalesce((select sum(sl.qty_base) from stock_ledger sl where sl.item_id = i.id), 0) as stock_base,
       i.image_url
from items i
left join pack_types pt on pt.id = i.pack_type_id
left join sections s on s.id = i.section_id
left join uoms u on u.id = i.base_uom_id;

alter view v_item_list set (security_invoker = on);

-- A recipe's ingredient rates: the production head's own costing, which he
-- may see. can_see_cost() includes production for exactly this screen.
create or replace view v_recipe_ingredients as
select ri.id, ri.recipe_id, ri.ingredient_id, ing.item_code, ing.name as ingredient_name,
       ri.qty_per_plate, ri.uom_id, u.code as uom_code,
       item_cost(ing.id)::numeric(12,2) as rate   -- was ing.purchase_rate
from recipe_ingredients ri
join items ing on ing.id = ri.ingredient_id
left join uoms u on u.id = ri.uom_id;

alter view v_recipe_ingredients set (security_invoker = on);

create or replace view v_recipe_list as
select r.id, r.org_id, r.item_id, i.item_code, i.name as item_name,
       i.units_per_box, i.pieces_per_unit,
       s.name as section_name, s.mestri_id, m.full_name as mestri_name,
       r.name, r.pieces_per_plate, r.is_active, r.created_at,
       coalesce((select count(*) from recipe_ingredients ri where ri.recipe_id = r.id), 0) as ingredient_count,
       round(r.pieces_per_plate / nullif(i.pieces_per_unit * i.units_per_box, 0)::numeric, 3) as boxes_per_plate,
       -- was sum(ri.qty_per_plate * coalesce(ing.purchase_rate, 0))
       coalesce((select sum(ri.qty_per_plate * coalesce(item_cost(ing.id), 0))
                   from recipe_ingredients ri
                   join items ing on ing.id = ri.ingredient_id
                  where ri.recipe_id = r.id), 0) as cost_per_plate
from recipes r
join items i on i.id = r.item_id
left join sections s on s.id = i.section_id
left join staff m on m.id = s.mestri_id;

alter view v_recipe_list set (security_invoker = on);

-- ------------------------------------------------------------
-- 3. And the columns come out of the grant
-- ------------------------------------------------------------
-- Every column EXCEPT the one, named explicitly: a column added to the table
-- later is then not readable until somebody grants it on purpose, which is the
-- safer way round for a table that holds a figure like this.
/**
 * Take the wage column out of the SELECT grant and put every other column of
 * staff back.
 *
 * A function rather than a one-off block because a blanket
 * `grant all on all tables` — which is what Supabase's default privileges do,
 * and what a later migration or a support session might run — silently puts
 * the column back. This can be run again afterwards to close it, and says
 * what it closed.
 *
 * WHY ONLY THE WAGE, AND NOT THE COST. The same treatment on
 * items.purchase_rate is what this file set out to do, and it cannot be done
 * this way: about fifteen functions written before this — save_invoice,
 * post_production, the trip loaders — hold an item in an `items%rowtype`
 * variable filled by `select * into it from items`. `select *` needs every
 * column, so taking one column out of the grant stops invoices being saved.
 * Proved by trying it: "permission denied for table items" from save_invoice.
 *
 * So the cost is closed one layer up instead, in the views above, which is
 * every path the app and every report actually read. What that does NOT close
 * is the table itself: somebody signed in who knows the API is there can still
 * ask it for items.purchase_rate directly. Closing that properly means moving
 * the cost onto its own table, gated like any other purchases data, and
 * reworking those fifteen functions — a job of its own, not a line in this
 * one. Until it is done, this file's claim is precise: the cost is off every
 * screen and every report, not out of the database.
 */
create or replace function lock_cost_and_wage_columns() returns text
language plpgsql security definer set search_path = public as $$
declare cols text; out text := '';
begin
  foreach cols in array array['staff:daily_wage'] loop
    declare
      v_tbl text := split_part(cols, ':', 1);
      v_col text := split_part(cols, ':', 2);
      v_keep text;
    begin
      -- Every column EXCEPT the one, named explicitly: a column added to the
      -- table later is then not readable until somebody grants it on purpose,
      -- which is the safer way round for a table holding a figure like this.
      select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
        into v_keep
        from information_schema.columns
       where table_schema = 'public' and table_name = v_tbl and column_name <> v_col;
      execute format('revoke select on %I from authenticated', v_tbl);
      execute format('grant select (%s) on %I to authenticated', v_keep, v_tbl);
      out := out || format('%s.%s closed; ', v_tbl, v_col);
    end;
  end loop;
  return out;
end $$;

select lock_cost_and_wage_columns();

-- Writing them is a different question, and already answered: insert and
-- update on items need can_edit('items'), on staff the owner or an admin. A
-- store keeper who may edit items may still set a cost; he simply cannot read
-- the column back through the table, which is why the item screen reads it
-- through item_cost().

comment on function can_see_cost() is
  'May the signed-in person see what things cost? Purchases or production only (db/71).';
comment on function item_cost(uuid) is
  'An item''s purchase rate, or null to a role with no business knowing it. items.purchase_rate itself is not readable by anyone signed in (db/71).';
comment on function staff_wage(uuid) is
  'A staff member''s daily wage, or null unless the role runs attendance or setup. staff.daily_wage itself is not readable by anyone signed in (db/71).';

-- ------------------------------------------------------------
-- 4. What the staff screen reads instead of `select *`
-- ------------------------------------------------------------
-- The wage column is no longer readable from the table by anybody signed in,
-- which includes the owner — so the users screen cannot ask for `*` any more.
-- It asks these two instead. They are definer functions, so they can read the
-- column, and they put the same question to the module gate that staff_wage()
-- does: the wage comes back to a role that runs attendance or setup, and null
-- to everyone else, on the same row as the name.
create or replace function staff_list()
returns table (id uuid, org_id uuid, auth_uid uuid, full_name text, phone text, role staff_role,
               daily_wage numeric, is_mestry boolean, is_active boolean, created_at timestamptz,
               punchly_user_id text, punchly_staff_id text, designation text)
language plpgsql stable security definer set search_path = public as $$
declare v_wages boolean := can_view('attendance') or can_view('setup');
begin
  if my_org_id() is null then return; end if;
  return query
    select s.id, s.org_id, s.auth_uid, s.full_name, s.phone, s.role,
           case when v_wages then s.daily_wage end,
           s.is_mestry, s.is_active, s.created_at,
           s.punchly_user_id, s.punchly_staff_id, s.designation
      from staff s
     where s.org_id = my_org_id()
     order by s.full_name;
end $$;

/**
 * Add or change a person. The same owner-or-admin rule staff_write has always
 * enforced, asked here because this writes through a definer and so bypasses
 * that policy — and the row is handed back through the same wage masking.
 *
 * Somebody who will never sign in needs no login: p_id null with no auth_uid
 * inserts a staff row, which is most of the list (drivers, mestris, anybody
 * who exists to be picked from a dropdown or counted in the register).
 */
create or replace function save_staff(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid := nullif(p->>'id', '')::uuid; v_role staff_role;
begin
  if v_org is null then raise exception 'Organisation not known'; end if;
  if not has_role('owner', 'admin') then raise exception 'Only an owner or admin can change staff'; end if;
  v_role := coalesce(nullif(p->>'role', '')::staff_role, 'sales_exec');
  -- An admin may not make somebody an owner, exactly as create-user refuses it.
  if my_role() = 'admin' and v_role in ('owner', 'admin') then
    raise exception 'An admin cannot make somebody an owner or admin';
  end if;

  if v_id is null then
    insert into staff (org_id, full_name, phone, role, daily_wage, is_mestry, is_active, designation)
    values (v_org, nullif(trim(p->>'full_name'), ''), nullif(trim(p->>'phone'), ''), v_role,
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
    role        = case when p ? 'role' then v_role else role end,
    daily_wage  = case when p ? 'daily_wage' then coalesce(nullif(p->>'daily_wage', '')::numeric, 0) else daily_wage end,
    is_mestry   = case when p ? 'is_mestry' then coalesce((p->>'is_mestry')::boolean, false) else is_mestry end,
    is_active   = case when p ? 'is_active' then coalesce((p->>'is_active')::boolean, true) else is_active end,
    designation = case when p ? 'designation' then nullif(trim(p->>'designation'), '') else designation end
   where id = v_id and org_id = v_org;
  if not found then raise exception 'Staff member not found'; end if;
  return v_id;
end $$;

grant execute on function staff_list() to authenticated;
grant execute on function save_staff(jsonb) to authenticated;
