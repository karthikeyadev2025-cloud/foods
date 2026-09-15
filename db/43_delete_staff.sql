-- ============================================================
-- JYOTHI FOODS ERP — 43: DELETING A USER, WITHOUT LOCKING ANYBODY OUT
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- delete_master('staff', …) has always known how to remove a staff row and what
-- stops it — a bill they entered, a receipt, a trip they drove, a section they
-- run. Nothing on the Users screen ever called it, so there was no way to be rid
-- of a person typed in by mistake.
--
-- Two things it does NOT know, because they are about signing in rather than
-- about references, and both of them lock somebody out for good:
--
--   1. Deleting YOURSELF. The row is gone, my_org_id() returns null, and the
--      next screen says you are not a member of any organisation. There is no
--      undo from inside the app, because you cannot get into the app.
--   2. Deleting the LAST OWNER. Nobody is left who can manage users, set the
--      licence or fix the first mistake.
--
-- So this wraps delete_master rather than restating it: the reference rules stay
-- in one place, and the two ways to lock the shop out of its own system are
-- refused here.
--
-- WHAT IT DOES NOT DO: remove the Supabase sign-in account. That lives outside
-- this database. The account survives and is inert — with no staff row it
-- belongs to no organisation and every screen refuses it — but it is still
-- listed under Authentication in Supabase, and should be deleted there too.
-- ============================================================

create or replace function delete_staff(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_org  uuid := my_org_id();
  s      staff%rowtype;
  n      bigint;
begin
  if v_org is null then raise exception 'Not signed in to an organisation'; end if;

  select * into s from staff where id = p_id and org_id = v_org;
  if not found then raise exception 'That user is not there any more'; end if;

  if p_id = my_staff_id() then
    raise exception 'You cannot delete your own login. Ask another owner to do it, or set yourself inactive.'
      using errcode = '42501';
  end if;

  if s.role = 'owner' then
    select count(*) into n from staff
     where org_id = v_org and role = 'owner' and is_active and id <> p_id;
    if n = 0 then
      raise exception '% is the only owner left. Make somebody else an owner first, or the shop is locked out of its own settings.',
        coalesce(s.full_name, 'This user') using errcode = '42501';
    end if;
  end if;

  -- Everything else — which bills, receipts and trips stand in the way — is
  -- delete_master's to decide, and its refusal is the one the screen shows.
  return delete_master('staff', p_id);
end $$;

revoke execute on function delete_staff(uuid) from public, anon;
grant  execute on function delete_staff(uuid) to authenticated;
