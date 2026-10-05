-- ============================================================
-- DB acceptance test: the business name can be taken off the prints.
-- Rolls back.
--
-- "I want to remove Jyothi Foods name also from invoice and quote and all in
--  all in prints."
--
-- The screens read the setting off v_me, so what matters here is that it
-- REACHES v_me, that it survives a round trip, and that it defaults to on —
-- a shop that has never heard of this must keep printing its own name.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid;
  v_shows boolean;
  uid uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');

  -- ============================================================
  -- 1. A SHOP THAT HAS NEVER ASKED KEEPS ITS NAME ON. The whole point of a
  --    default is that nobody's prints change until they say so.
  -- ============================================================
  select print_org_name into v_shows from v_me;
  assert v_shows, '48.1 a new shop would print its documents with no name on them';

  -- ============================================================
  -- 2. THE SETTING REACHES THE SCREENS. They read the org from v_me and
  --    nowhere else, so a column that is on orgs but not on v_me is a
  --    setting that does nothing — which is worse than no setting at all,
  --    because the switch moves and the print does not.
  -- ============================================================
  update orgs set print_org_name = false where id = v_org;
  select print_org_name into v_shows from v_me;
  assert not v_shows, '48.2 the switch was turned off and v_me still reports the name as printed';

  --    And back again: this is paper the shop changes, not a one-way door.
  update orgs set print_org_name = true where id = v_org;
  select print_org_name into v_shows from v_me;
  assert v_shows, '48.3 the name could be turned off but not back on';

  -- ============================================================
  -- 3. IT IS NOT NULLABLE. A null would read as neither on nor off, and every
  --    screen would have to guess which — the kind of three-state that ends with
  --    one print showing the name and another not.
  -- ============================================================
  begin
    update orgs set print_org_name = null where id = v_org;
    raise exception '48.4 the setting accepted a null';
  exception when not_null_violation then null;
  end;

  raise notice 'OK: the business name comes off the prints from one switch — a new shop still prints its name, turning the switch off reaches v_me where every screen reads it, it turns back on again, and it can never be left null for a screen to guess at';
end $$;

rollback;
