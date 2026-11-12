-- ============================================================
-- DB acceptance test: the shop names its own jobs.
--
-- There were eight roles and no ninth. A shop with a packing section, a night
-- godown and a supervisor had to pretend those people were a sales exec.
--
-- The tests that matter here are not "can I make a role" — they are the ones
-- where a new role could be used to get rights nobody meant to give:
-- a role based on the owner, an admin inventing one and taking it, a role
-- handed to somebody by a person who may not promote, and the module gates
-- still answering correctly once two different roles share one built-in.
--
-- Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; owner_uid uuid := gen_random_uuid(); admin_uid uuid := gen_random_uuid(); packer_uid uuid := gen_random_uuid();
  v_packing uuid; v_night uuid; v_super uuid; v_staff uuid; v_msg text; n int; r record;
begin
  perform set_config('request.jwt.claim.sub', owner_uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');

  -- ===== 61.1 the eight built-ins exist as rows, named and renameable =====
  select count(*) into n from role_list();
  assert n = 8, format('61.1 a new shop starts with the eight built-in roles, has %s', n);
  select count(*) into n from role_list() where is_system;
  assert n = 8, '61.1 and all eight are system roles';
  select name into v_msg from role_list() where based_on = 'sales_exec';
  assert v_msg = 'Sales / counter', format('61.1 named for the shop, not for the enum: %s', v_msg);

  -- the owner renames one to what the shop actually calls it
  select id into v_staff from role_list() where based_on = 'chief';
  perform save_role(jsonb_build_object('id', v_staff, 'name', 'Mestri'));
  select name, is_system into r from role_list() where id = v_staff;
  assert r.name = 'Mestri' and r.is_system, '61.1 a built-in can be renamed and stays a built-in';

  -- ===== 61.2 a role the shop invented =====
  v_packing := save_role(jsonb_build_object('name', 'Packing in-charge', 'based_on', 'store_keeper'));
  v_night   := save_role(jsonb_build_object('name', 'Night godown', 'based_on', 'store_keeper'));
  select count(*) into n from role_list();
  assert n = 10, format('61.2 ten roles now, has %s', n);

  -- it starts from the built-in's rights rather than from nothing
  select count(*) into n from role_permissions where role_id = v_packing and can_view;
  assert n = 6, format('61.2 a new role starts from its built-in''s defaults, %s modules', n);

  -- ===== 61.3 two roles on one built-in can have DIFFERENT rights =====
  -- This is what the old one-row-per-enum-role matrix made impossible.
  update role_permissions set can_view = false, can_edit = false
   where role_id = v_night and module = 'purchases';
  select can_view into r from role_permissions where role_id = v_packing and module = 'purchases';
  assert r.can_view, '61.3 packing keeps purchases';
  select can_view into r from role_permissions where role_id = v_night and module = 'purchases';
  assert not r.can_view, '61.3 while night godown does not — same built-in, different rights';

  -- ===== 61.4 the gates answer by the role the person holds =====
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  insert into staff (org_id, auth_uid, full_name, role_id) values (v_org, packer_uid, 'Packing boy', v_night)
    returning id into v_staff;
  -- the trigger put the enum where the hard-wired checks can read it
  select role, role_id into r from staff where id = v_staff;
  assert r.role = 'store_keeper' and r.role_id = v_night,
    format('61.4 the enum follows the role''s based_on: %s', to_jsonb(r));

  perform set_config('request.jwt.claim.sub', packer_uid::text, true); set local role authenticated;
  assert my_role() = 'store_keeper', format('61.4 my_role() still answers an enum: %s', my_role());
  assert my_role_id() = v_night, '61.4 and my_role_id() the row';
  assert not can_view('purchases'), '61.4 night godown must NOT see purchases, as the shop set it';
  assert can_view('stock'), '61.4 but still sees stock';
  -- and the other role on the same built-in is unaffected
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  update staff set role_id = v_packing where id = v_staff;
  perform set_config('request.jwt.claim.sub', packer_uid::text, true); set local role authenticated;
  assert can_view('purchases'), '61.4 moved to packing in-charge, he sees purchases again';

  -- ===== 61.5 nobody invents their way to being the owner =====
  reset role; perform set_config('request.jwt.claim.sub', owner_uid::text, true); set local role authenticated;
  begin
    perform save_role(jsonb_build_object('name', 'Boss', 'based_on', 'owner'));
    raise exception '61.5 a role was based on Owner';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%cannot be based on Owner%', format('61.5 wrong reason: %s', v_msg);
  end;

  -- an admin may not create roles at all
  reset role; perform set_config('request.jwt.claim.sub', '', true);
  insert into staff (org_id, auth_uid, full_name, role) values (v_org, admin_uid, 'Manager', 'admin');
  perform set_config('request.jwt.claim.sub', admin_uid::text, true); set local role authenticated;
  assert my_role() = 'admin', '61.5 this is the manager';
  begin
    perform save_role(jsonb_build_object('name', 'Deputy boss', 'based_on', 'admin'));
    raise exception '61.5 an admin invented a role';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%Only the owner%', format('61.5 wrong reason: %s', v_msg);
  end;

  -- nor hand out a manager's role to anybody, himself included
  reset role; perform set_config('request.jwt.claim.sub', owner_uid::text, true); set local role authenticated;
  v_super := save_role(jsonb_build_object('name', 'Supervisor', 'based_on', 'admin'));
  reset role; perform set_config('request.jwt.claim.sub', admin_uid::text, true); set local role authenticated;
  begin
    perform set_staff_role(v_staff, v_super);
    raise exception '61.5 an admin handed out a manager-level role';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%cannot make somebody an owner or a manager%', format('61.5 wrong reason: %s', v_msg);
  end;
  -- but he may move somebody between ordinary roles
  perform set_staff_role(v_staff, v_night);
  select role_id into v_msg from staff where id = v_staff;
  assert v_msg::uuid = v_night, '61.5 an admin can still move people between ordinary roles';

  -- ===== 61.6 a role in use cannot be deleted, a built-in never =====
  reset role; perform set_config('request.jwt.claim.sub', owner_uid::text, true); set local role authenticated;
  begin
    perform delete_role(v_night);
    raise exception '61.6 deleted a role somebody holds';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%still have this role%', format('61.6 wrong reason: %s', v_msg);
  end;
  begin
    perform delete_role((select id from role_list() where based_on = 'driver'));
    raise exception '61.6 deleted a built-in role';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    assert v_msg like '%built-in%', format('61.6 wrong reason: %s', v_msg);
  end;
  -- an unused custom role goes, and takes its permission rows with it
  perform delete_role(v_super);
  select count(*) into n from role_permissions where role_id = v_super;
  assert n = 0, '61.6 and its permission rows go with it';

  -- ===== 61.7 the owner is still the owner =====
  -- Every hard-wired check in the other files reads my_role(), so a custom
  -- role must never make somebody an owner by accident.
  select count(*) into n from staff s join roles ro on ro.id = s.role_id
   where s.org_id = v_org and ro.based_on = 'owner';
  assert n = 1, format('61.7 exactly one person is based on owner, found %s', n);

  -- ===== 61.8 the roles are in the backup, ahead of what points at them =====
  assert array_position(snapshot_tables(), 'roles') = 1, '61.8 roles is restored first';
  assert array_position(snapshot_tables(), 'roles') < array_position(snapshot_tables(), 'role_permissions'),
    '61.8 before the permission rows that reference it';
  assert array_position(snapshot_tables(), 'roles') < array_position(snapshot_tables(), 'staff'),
    '61.8 and before the staff that hold it';

  reset role;
  raise notice 'OK: a shop names its own jobs — the eight built-ins are rows it can rename but not delete, it can invent as many more as it likes, and two roles based on the same built-in can carry different rights, which the old one-row-per-role matrix made impossible. my_role() still answers with an enum so every hard-wired check in the other seventy files keeps its meaning. No role may be based on Owner, an admin may not invent a role nor hand out an owner- or manager-level one, a role somebody holds cannot be deleted, and the roles are restored from a backup before the staff and permissions that point at them';
end $$;

rollback;
