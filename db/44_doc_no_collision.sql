-- ============================================================
-- JYOTHI FOODS ERP — 44: A DOCUMENT NUMBER THAT IS ALREADY TAKEN
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- From a real till:
--
--   POST /rpc/save_invoice 409
--   23505 duplicate key value violates unique constraint
--         "invoices_org_id_invoice_no_key"
--
-- The counter handed back a number that an invoice already had, so the bill
-- could not be saved at all. Nothing in the counter is racy — it takes a row
-- lock and increments under it — the counter had simply fallen BEHIND the
-- documents. Several ordinary things do that:
--
--   * Setup → Numbering lets somebody type next_number. Typing a smaller one
--     walks the counter straight back over bills that exist.
--   * reset_period. On a monthly or yearly series with no month or year in the
--     prefix, the reset puts the counter back to 1 — onto numbers last period
--     already used. A plain 0011 collides with the 0011 from December.
--   * Rows restored from a backup, or loaded in, without the counter moving.
--
-- Guessing which one happened here does not matter, because the answer is the
-- same for all of them and for the next one nobody has thought of: A NUMBER
-- THAT IS ALREADY IN USE IS NOT FREE, so do not hand it out. next_doc_no now
-- looks, skips what is taken, and leaves the counter past it.
--
-- resync_doc_numbers() does the same thing in one go for a database that is
-- already behind, so the first bill after this is not a series of retries.
-- ============================================================

-- Where each kind of document keeps its number. Anything not listed keeps the
-- old behaviour exactly — the counter, unchecked — rather than guessing at a
-- table name and failing on a database that does not have it.
create or replace function doc_no_home(p_doc_type text)
returns table (tbl text, col text) language sql immutable as $$
  select t.tbl, t.col from (values
    ('invoice',         'invoices',           'invoice_no'),
    ('sale',            'invoices',           'invoice_no'),
    ('receipt',         'receipts',           'receipt_no'),
    ('payment',         'payments',           'payment_no'),
    ('purchase',        'purchases',          'bill_no'),
    ('return',          'sales_returns',      'return_no'),
    ('sale_return',     'sales_returns',      'return_no'),
    ('purchase_return', 'purchase_returns',   'return_no'),
    ('quotation',       'quotations',         'quote_no'),
    ('sale_order',      'orders',             'order_no'),
    ('purchase_order',  'orders',             'order_no'),
    ('challan',         'delivery_challans',  'challan_no'),
    ('batch',           'production_batches', 'batch_no'),
    ('stock_count',     'stock_counts',       'count_no'),
    ('stock_transfer',  'stock_transfers',    'transfer_no'),
    ('transfer',        'stock_transfers',    'transfer_no'),
    ('journal',         'journal_entries',    'entry_no')
  ) as t(doc_type, tbl, col)
  where t.doc_type = p_doc_type;
$$;

create or replace function next_doc_no(p_org uuid, p_doc_type text)
returns text language plpgsql security definer set search_path = public as $$
declare
  ns      number_series%rowtype;
  v_reset boolean := false;
  h       record;
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

  select * into h from doc_no_home(p_doc_type);

  loop
    v_no := coalesce(ns.prefix, '') || lpad(ns.next_number::text, ns.width, '0') || coalesce(ns.suffix, '');

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

  -- Past the number just handed out, whether it took one step or a thousand.
  update number_series set next_number = ns.next_number + 1, last_reset = current_date
   where id = ns.id;

  return v_no;
end $$;

/**
 * Walk every counter past the documents that already exist.
 *
 * For a database where this has already happened: without it the first bill
 * after the fix climbs one number at a time from wherever the counter is, which
 * works but is slow and looks alarming. Reads only the numbers that match the
 * series' own shape — a hand-typed bill number on a purchase is left alone
 * rather than dragging the counter somewhere it has no business being.
 */
create or replace function resync_doc_numbers() returns table (doc_type text, was bigint, now_at bigint)
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := my_org_id();
  ns    record;
  h     record;
  v_max bigint;
  v_pat text;
begin
  if v_org is null then raise exception 'Not signed in to an organisation'; end if;
  if not can_edit('setup') then
    raise exception 'Only somebody who can edit Setup can resynchronise the numbering' using errcode = '42501';
  end if;

  for ns in select * from number_series where org_id = v_org order by doc_type loop
    select * into h from doc_no_home(ns.doc_type);
    continue when h.tbl is null;

    -- Only numbers shaped like this series: prefix, digits, suffix.
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

revoke execute on function resync_doc_numbers() from public, anon;
grant  execute on function resync_doc_numbers() to authenticated;
