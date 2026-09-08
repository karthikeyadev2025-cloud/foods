-- ============================================================
-- JYOTHI FOODS ERP — 13: HEY NIKKI MESSAGING (T6)
-- The ERP owns the data; Hey Nikki only sends, listens and
-- transcribes. Everything outbound goes through message_log
-- (queued → sent → delivered/read/failed); everything inbound
-- lands in inbound_orders for a human to confirm. Nothing here
-- creates an invoice by itself.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Settings — one row per org. The API key never reaches the
--    browser: the table has no policy for signed-in users, the
--    screen reads a masked copy through get_messaging_settings().
-- ------------------------------------------------------------
create table if not exists messaging_settings (
  org_id           uuid primary key references orgs(id) on delete cascade,
  api_url          text not null default 'https://heynikki.in',
  api_key          text,
  -- 48 hex characters, from core gen_random_uuid() rather than pgcrypto's
  -- gen_random_bytes() — see rotate_webhook_secret() below for why.
  webhook_secret   text not null default substr(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 1, 48),
  sender_number    text,
  default_language text not null default 'te',
  quiet_from       time not null default '21:00',
  quiet_to         time not null default '08:00',
  daily_cap        integer not null default 500 check (daily_cap > 0),
  is_enabled       boolean not null default false,
  updated_at       timestamptz not null default now()
);
-- `create table if not exists` leaves an existing table's defaults alone, so state it
-- again here: a database built before the pgcrypto fix still carries the old expression.
alter table messaging_settings alter column webhook_secret
  set default substr(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 1, 48);
alter table messaging_settings enable row level security;
create unique index if not exists messaging_settings_secret_idx on messaging_settings(webhook_secret);

create or replace function normalize_mobile(p text) returns text
language sql immutable as $$
  select nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '');
$$;

/** True when nobody is signed in — the service role (edge functions, pg_cron) calling in. */
create or replace function is_service_call() returns boolean
language sql stable as $$ select auth.uid() is null $$;

create or replace function get_messaging_settings() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s messaging_settings%rowtype;
begin
  if not can_view('messaging') then raise exception 'Messaging is not available to your role'; end if;
  insert into messaging_settings (org_id) values (v_org) on conflict (org_id) do nothing;
  select * into s from messaging_settings where org_id = v_org;
  return jsonb_build_object(
    'api_url', s.api_url,
    'has_api_key', s.api_key is not null,
    'api_key_hint', case when s.api_key is null then null else '••••' || right(s.api_key, 4) end,
    'webhook_secret', s.webhook_secret,
    'sender_number', s.sender_number,
    'default_language', s.default_language,
    'quiet_from', s.quiet_from, 'quiet_to', s.quiet_to,
    'daily_cap', s.daily_cap, 'is_enabled', s.is_enabled, 'updated_at', s.updated_at);
end $$;

create or replace function save_messaging_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id();
begin
  if not can_edit('messaging') then raise exception 'Only a role with Messaging edit rights can change these settings'; end if;
  insert into messaging_settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update messaging_settings set
    api_url          = coalesce(nullif(p->>'api_url', ''), api_url),
    api_key          = case when nullif(p->>'api_key', '') is not null then p->>'api_key' else api_key end,
    sender_number    = coalesce(nullif(p->>'sender_number', ''), sender_number),
    default_language = coalesce(nullif(p->>'default_language', ''), default_language),
    quiet_from       = coalesce(nullif(p->>'quiet_from', '')::time, quiet_from),
    quiet_to         = coalesce(nullif(p->>'quiet_to', '')::time, quiet_to),
    daily_cap        = coalesce(nullif(p->>'daily_cap', '')::int, daily_cap),
    is_enabled       = coalesce((p->>'is_enabled')::boolean, is_enabled),
    updated_at       = now()
  where org_id = v_org;
  return get_messaging_settings();
end $$;

create or replace function rotate_webhook_secret() returns text
language plpgsql security definer set search_path = public as $$
-- gen_random_bytes() is pgcrypto. Supabase installs pgcrypto into the extensions
-- schema, and this function pins search_path to public, so the call resolves on a
-- plain Postgres and fails on Supabase with "function does not exist".
-- gen_random_uuid() is core Postgres and needs no extension at all.
declare v_secret text := substr(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 1, 48);
begin
  if not can_edit('messaging') then raise exception 'Only a role with Messaging edit rights can rotate the secret'; end if;
  update messaging_settings set webhook_secret = v_secret, updated_at = now() where org_id = my_org_id();
  return v_secret;
end $$;

-- ------------------------------------------------------------
-- 2. Templates. {{name}} {{town}} {{org}} {{outstanding}}
--    {{oldest_days}} {{invoice_no}} {{amount}} {{date}} {{items}}
--    {{receipt_no}} {{item}} {{boxes}} {{catalog}} {{valid_to}}
-- ------------------------------------------------------------
alter table message_templates add column if not exists updated_at timestamptz not null default now();
create unique index if not exists message_templates_name_idx on message_templates(org_id, name);
alter table customers add column if not exists language text not null default 'te';

create or replace function render_template(p_body text, p_vars jsonb) returns text
language plpgsql immutable as $$
declare k text; v text; v_out text := coalesce(p_body, '');
begin
  for k, v in select key, value from jsonb_each_text(coalesce(p_vars, '{}'::jsonb)) loop
    v_out := replace(v_out, '{{' || k || '}}', coalesce(v, ''));
  end loop;
  return v_out;
end $$;

/** The active template for a purpose in the customer's language, else any language. */
create or replace function pick_template(p_org uuid, p_purpose msg_purpose, p_language text)
returns message_templates language sql stable as $$
  select t from message_templates t
   where t.org_id = p_org and t.purpose = p_purpose and t.is_active
   order by (t.language = p_language) desc, (t.language = 'te') desc, t.name
   limit 1;
$$;

-- ------------------------------------------------------------
-- 3. The outbound queue.
-- ------------------------------------------------------------
alter table message_log
  add column if not exists body text,
  add column if not exists ref_table text,
  add column if not exists ref_id uuid,
  add column if not exists rule_id uuid references reminder_rules(id) on delete set null,
  add column if not exists broadcast_id uuid,
  add column if not exists delivered_at timestamptz,
  add column if not exists read_at timestamptz,
  add column if not exists attempts integer not null default 0,
  add column if not exists updated_at timestamptz not null default now();
create index if not exists message_log_queue_idx on message_log(org_id, status, created_at) where status = 'queued';
create unique index if not exists message_log_provider_idx on message_log(provider_msg_id) where provider_msg_id is not null;

/**
 * queue_message({customer_id, purpose, template_id?, vars?, body?, media_url?, channel?,
 *                ref_table?, ref_id?, rule_id?, broadcast_id?})
 * Returns the message_log id, or NULL when the customer has opted out or has no mobile.
 * Definer so document triggers can queue for any role; a signed-in caller is pinned to
 * their own org.
 */
create or replace function queue_message(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare c customers%rowtype; t message_templates; v_vars jsonb; v_body text; v_id uuid; v_to text; v_purpose msg_purpose; v_media text;
begin
  select * into c from customers where id = (p->>'customer_id')::uuid;
  if not found then raise exception 'Customer not found'; end if;
  if not is_service_call() and c.org_id is distinct from my_org_id() then
    raise exception 'Customer belongs to another organisation';
  end if;
  v_purpose := (p->>'purpose')::msg_purpose;
  v_to := normalize_mobile(coalesce(nullif(p->>'to_number', ''), c.mobile1));
  if v_to is null or not c.whatsapp_opt_in then return null; end if;

  if nullif(p->>'template_id', '') is not null then
    select * into t from message_templates where id = (p->>'template_id')::uuid and org_id = c.org_id;
  else
    t := pick_template(c.org_id, v_purpose, c.language);
  end if;

  v_vars := jsonb_build_object(
              'org', (select name from orgs where id = c.org_id),
              'name', c.name, 'town', coalesce(c.town, ''),
              'outstanding', to_char(coalesce((select outstanding from v_customer_outstanding where customer_id = c.id), 0), 'FM9,99,99,990.00'),
              'date', to_char(current_date, 'DD-MM-YYYY'))
            || coalesce(p->'vars', '{}'::jsonb);
  v_body := coalesce(nullif(p->>'body', ''), render_template(t.body, v_vars));
  if v_body is null or v_body = '' then
    raise exception 'No active % template for %', v_purpose, c.name;
  end if;
  v_media := nullif(p->>'media_url', '');

  insert into message_log (org_id, customer_id, template_id, channel, purpose, to_number, body, payload, status,
                           ref_table, ref_id, rule_id, broadcast_id)
  values (c.org_id, c.id, t.id, coalesce(nullif(p->>'channel', '')::channel_kind, t.channel, 'whatsapp'), v_purpose, v_to, v_body,
          jsonb_strip_nulls(jsonb_build_object('vars', v_vars, 'media_url', v_media,
                                               'template_name', t.provider_template_name, 'language', coalesce(t.language, c.language))),
          'queued', nullif(p->>'ref_table', ''), nullif(p->>'ref_id', '')::uuid,
          nullif(p->>'rule_id', '')::uuid, nullif(p->>'broadcast_id', '')::uuid)
  returning id into v_id;
  return v_id;
end $$;

/** Send a one-off message from the screen (custom purpose, free text). */
create or replace function send_custom_message(p_customer uuid, p_body text, p_media_url text default null) returns uuid
language sql as $$
  select queue_message(jsonb_build_object('customer_id', p_customer, 'purpose', 'custom', 'body', p_body, 'media_url', p_media_url));
$$;

/**
 * What the sender may send now: nothing inside quiet hours (IST), never more than the
 * daily cap. Service role only — the edge function calls this.
 */
create or replace function claim_queued_messages(p_org uuid, p_limit int default 50)
returns setof message_log language plpgsql security definer set search_path = public as $$
declare s messaging_settings%rowtype; v_now time; v_sent_today int;
begin
  if not is_service_call() then raise exception 'Sender only'; end if;
  select * into s from messaging_settings where org_id = p_org;
  if not found or not s.is_enabled or s.api_key is null then return; end if;
  v_now := (now() at time zone 'Asia/Kolkata')::time;
  if (s.quiet_from > s.quiet_to and (v_now >= s.quiet_from or v_now < s.quiet_to))
     or (s.quiet_from < s.quiet_to and v_now >= s.quiet_from and v_now < s.quiet_to) then
    return;
  end if;
  select count(*) into v_sent_today from message_log
   where org_id = p_org and sent_at >= (now() at time zone 'Asia/Kolkata')::date;
  if v_sent_today >= s.daily_cap then return; end if;
  return query
    update message_log set attempts = attempts + 1, updated_at = now()
     where id in (select id from message_log where org_id = p_org and status = 'queued' and attempts < 3
                   order by created_at limit least(p_limit, s.daily_cap - v_sent_today))
    returning *;
end $$;

/** Status webhook: sent / delivered / read / failed, matched on the provider's id. */
create or replace function mark_message_status(p_provider_msg_id text, p_status msg_status, p_error text default null, p_at timestamptz default now())
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update message_log set
    status = case
      -- never go backwards: read stays read, delivered is not undone by a late 'sent'
      when status = 'read' and p_status <> 'failed' then status
      when status = 'delivered' and p_status = 'sent' then status
      else p_status end,
    delivered_at = case when p_status = 'delivered' then coalesce(delivered_at, p_at) else delivered_at end,
    read_at      = case when p_status = 'read' then coalesce(read_at, p_at) else read_at end,
    error        = case when p_status = 'failed' then p_error else error end,
    updated_at   = now()
  where provider_msg_id = p_provider_msg_id;
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace view v_message_log as
select m.id, m.org_id, m.customer_id, c.name as customer_name, c.town, m.to_number, m.channel, m.purpose, m.status,
       m.body, m.error, m.template_id, t.name as template_name, m.provider_msg_id, m.payload->>'media_url' as media_url,
       m.ref_table, m.ref_id, m.rule_id, r.name as rule_name, m.broadcast_id, m.attempts,
       m.sent_at, m.delivered_at, m.read_at, m.created_at
  from message_log m
  left join customers c on c.id = m.customer_id
  left join message_templates t on t.id = m.template_id
  left join reminder_rules r on r.id = m.rule_id;
alter view v_message_log set (security_invoker = on);

-- ------------------------------------------------------------
-- 4. Transactional messages: invoice copy on dispatch, delivery
--    confirmation, receipt acknowledgement, order acknowledgement.
--    Switched per document in transaction_message_settings.
-- ------------------------------------------------------------
drop policy if exists org_read on transaction_message_settings;
drop policy if exists org_write on transaction_message_settings;

create or replace function queue_document_message(p_doc_type text, p_customer uuid, p_vars jsonb, p_ref_table text, p_ref_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare s transaction_message_settings%rowtype; v_org uuid; v_purpose msg_purpose;
begin
  select org_id into v_org from customers where id = p_customer;
  select * into s from transaction_message_settings where org_id = v_org and doc_type = p_doc_type and is_enabled;
  if not found then return null; end if;
  if not exists (select 1 from messaging_settings where org_id = v_org and is_enabled) then return null; end if;
  v_purpose := case p_doc_type when 'invoice' then 'invoice' when 'delivery' then 'delivery'
                               when 'order_ack' then 'order_ack' else 'custom' end;
  return queue_message(jsonb_build_object('customer_id', p_customer, 'purpose', v_purpose, 'template_id', s.template_id,
                                          'vars', p_vars, 'ref_table', p_ref_table, 'ref_id', p_ref_id));
exception when others then
  -- A missing template must never block the document itself.
  raise warning 'Message for % % not queued: %', p_doc_type, p_ref_id, sqlerrm;
  return null;
end $$;

create or replace function invoice_message_vars(p_invoice uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'invoice_no', i.invoice_no, 'amount', to_char(i.total, 'FM9,99,99,990.00'), 'date', to_char(i.invoice_date, 'DD-MM-YYYY'),
    'items', (select string_agg(it.item_code || ' × ' || trim(to_char(ii.boxes, 'FM9990.##')), ', ' order by ii.id)
                from invoice_items ii join items it on it.id = ii.item_id where ii.invoice_id = i.id),
    'boxes', trim(to_char((select coalesce(sum(boxes), 0) from invoice_items where invoice_id = i.id), 'FM9990.##')))
  from invoices i where i.id = p_invoice;
$$;

create or replace function t_invoice_message() returns trigger language plpgsql as $$
begin
  if new.status = 'dispatched' and old.status is distinct from 'dispatched' then
    perform queue_document_message('invoice', new.customer_id, invoice_message_vars(new.id), 'invoices', new.id);
  elsif new.status = 'delivered' and old.status is distinct from 'delivered' then
    perform queue_document_message('delivery', new.customer_id, invoice_message_vars(new.id), 'invoices', new.id);
  end if;
  return null;
end $$;
drop trigger if exists t_invoice_message on invoices;
create trigger t_invoice_message after update of status on invoices for each row execute function t_invoice_message();

create or replace function t_receipt_message() returns trigger language plpgsql as $$
begin
  perform queue_document_message('receipt', new.customer_id,
    jsonb_build_object('receipt_no', new.receipt_no, 'amount', to_char(new.total_amount, 'FM9,99,99,990.00'),
                       'date', to_char(new.receipt_date, 'DD-MM-YYYY')),
    'receipts', new.id);
  return null;
end $$;
drop trigger if exists t_receipt_message on receipts;
-- save_receipt inserts the header at 0 and sets the total once the lines are in.
create trigger t_receipt_message after update of total_amount on receipts for each row
  when (old.total_amount = 0 and new.total_amount > 0) execute function t_receipt_message();

-- ------------------------------------------------------------
-- 5. Reminder engine. Rules are the ladder: a customer matches the
--    rule with the highest overdue_days they have crossed (gentle →
--    firm → call). One reminder per customer per repeat_every_days.
-- ------------------------------------------------------------
alter table reminder_rules
  add column if not exists repeat_every_days integer not null default 7 check (repeat_every_days > 0),
  add column if not exists channel channel_kind not null default 'whatsapp',
  add column if not exists route_id uuid references routes(id) on delete set null,
  add column if not exists last_run_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

create or replace view v_reminder_rules as
select r.*, t.name as template_name, t.language as template_language, rt.name as route_name,
       (select count(*) from message_log m where m.rule_id = r.id) as sent_total,
       (select max(created_at) from message_log m where m.rule_id = r.id) as last_sent_at
  from reminder_rules r
  left join message_templates t on t.id = r.template_id
  left join routes rt on rt.id = r.route_id;
alter view v_reminder_rules set (security_invoker = on);

/** Everyone the rule would reach today, with the reason it would skip them. */
create or replace function reminder_recipients(p_rule uuid)
returns table (customer_id uuid, name text, town text, mobile1 text, outstanding numeric, overdue_days integer,
               last_reminder_at timestamptz, due boolean, skip_reason text)
language sql stable security definer set search_path = public as $$
  with r as (select rr.*, coalesce(o.credit_days, 0) as credit_days from reminder_rules rr join orgs o on o.id = rr.org_id where rr.id = p_rule),
  cust as (
    select c.id, c.name, c.town, c.mobile1, c.route_id, c.whatsapp_opt_in,
           coalesce(vo.outstanding, 0) as outstanding,
           (current_date - (select min(b.invoice_date) from v_invoice_balance b
                              where b.customer_id = c.id and b.balance > 0 and b.status not in ('draft', 'cancelled'))
              - (select credit_days from r))::int as overdue_days,
           (select max(m.created_at) from message_log m where m.customer_id = c.id and m.purpose = 'payment_reminder' and m.status <> 'failed') as last_reminder_at
      from customers c
      left join v_customer_outstanding vo on vo.customer_id = c.id
     where c.org_id = (select org_id from r) and c.is_active
       and ((select route_id from r) is null or c.route_id = (select route_id from r))),
  matched as (
    select cust.* from cust, r
     where cust.outstanding >= r.min_outstanding and cust.overdue_days >= r.overdue_days
       -- a firmer rule takes the customer instead
       and not exists (select 1 from reminder_rules r2
                        where r2.org_id = r.org_id and r2.is_active and r2.id <> r.id
                          and r2.overdue_days > r.overdue_days and cust.overdue_days >= r2.overdue_days
                          and cust.outstanding >= r2.min_outstanding
                          and (r2.route_id is null or r2.route_id = cust.route_id)))
  select m.id, m.name, m.town, m.mobile1, m.outstanding, m.overdue_days, m.last_reminder_at,
         m.whatsapp_opt_in and normalize_mobile(m.mobile1) is not null
           and (m.last_reminder_at is null or m.last_reminder_at < now() - make_interval(days => (select repeat_every_days from r))) as due,
         case when not m.whatsapp_opt_in then 'opted out'
              when normalize_mobile(m.mobile1) is null then 'no mobile'
              when m.last_reminder_at >= now() - make_interval(days => (select repeat_every_days from r))
                then 'reminded ' || (current_date - m.last_reminder_at::date) || ' days ago'
              end as skip_reason
    from matched m
   order by m.outstanding desc;
$$;

create or replace function run_reminder_rule(p_rule uuid, p_dry_run boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reminder_rules%rowtype; rec record; v_queued int := 0; v_candidates int := 0; v_skipped jsonb := '[]'::jsonb; v_id uuid;
begin
  select * into r from reminder_rules where id = p_rule;
  if not found then raise exception 'Rule not found'; end if;
  if not is_service_call() and (r.org_id is distinct from my_org_id() or not can_edit('messaging')) then
    raise exception 'Not allowed to run this rule';
  end if;
  for rec in select * from reminder_recipients(p_rule) loop
    v_candidates := v_candidates + 1;
    if not rec.due then
      v_skipped := v_skipped || jsonb_build_object('name', rec.name, 'reason', rec.skip_reason);
      continue;
    end if;
    if not p_dry_run then
      v_id := queue_message(jsonb_build_object('customer_id', rec.customer_id, 'purpose', r.purpose, 'template_id', r.template_id,
                'channel', r.channel, 'rule_id', r.id,
                'vars', jsonb_build_object('outstanding', to_char(rec.outstanding, 'FM9,99,99,990.00'), 'oldest_days', rec.overdue_days)));
      if v_id is not null then v_queued := v_queued + 1; end if;
    else
      v_queued := v_queued + 1;
    end if;
  end loop;
  if not p_dry_run then update reminder_rules set last_run_at = now() where id = p_rule; end if;
  return jsonb_build_object('rule', r.name, 'dry_run', p_dry_run, 'candidates', v_candidates, 'queued', v_queued, 'skipped', v_skipped);
end $$;

/** Every active rule, for one org or (service role) all orgs with messaging switched on. */
create or replace function run_reminders(p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_out jsonb := '[]'::jsonb;
begin
  for r in select rr.id from reminder_rules rr join messaging_settings s on s.org_id = rr.org_id
            where rr.is_active and s.is_enabled and (p_org is null or rr.org_id = p_org)
            order by rr.overdue_days desc loop
    v_out := v_out || run_reminder_rule(r.id, false);
  end loop;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 6. Broadcasts: new stock (to recent buyers of that item) and
--    catalogs (to a segment). A broadcast row is the audit trail;
--    queue_broadcast() fans it out into message_log.
-- ------------------------------------------------------------
create table if not exists new_stock_rules (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  item_id         uuid not null references items(id) on delete cascade,
  threshold_boxes numeric(12,3) not null check (threshold_boxes > 0),
  lookback_days   integer not null default 60 check (lookback_days > 0),
  template_id     uuid references message_templates(id) on delete set null,
  auto_send       boolean not null default false,
  is_active       boolean not null default true,
  updated_at      timestamptz not null default now(),
  unique (org_id, item_id)
);
alter table new_stock_rules enable row level security;

create table if not exists broadcasts (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  kind        text not null check (kind in ('new_stock', 'catalog', 'custom')),
  item_id     uuid references items(id) on delete set null,
  catalog_id  uuid references catalogs(id) on delete set null,
  template_id uuid references message_templates(id) on delete set null,
  body        text,
  segment     jsonb not null default '{}'::jsonb,   -- {route_id, town, bought_item_id, bought_within_days}
  status      text not null default 'pending' check (status in ('pending', 'queued', 'cancelled')),
  recipients  integer not null default 0,
  note        text,
  created_by  uuid references staff(id),
  created_at  timestamptz not null default now(),
  queued_at   timestamptz
);
alter table broadcasts enable row level security;
create index if not exists broadcasts_org_idx on broadcasts(org_id, status, created_at desc);

alter table catalogs add column if not exists file_path text, add column if not exists updated_at timestamptz not null default now();

do $$
declare r record;
begin
  for r in select * from (values
      ('new_stock_rules',              'messaging', true),
      ('broadcasts',                   'messaging', true),
      ('transaction_message_settings', 'messaging', true)
    ) as t(tbl, module, gate_read)
  loop
    execute format('drop policy if exists org_read on %I', r.tbl);
    execute format('drop policy if exists mod_insert on %I', r.tbl);
    execute format('drop policy if exists mod_update on %I', r.tbl);
    execute format('drop policy if exists mod_delete on %I', r.tbl);
    execute format('create policy org_read on %I for select using (org_id = my_org_id() and can_view(%L))', r.tbl, r.module);
    execute format('create policy mod_insert on %I for insert with check (org_id = my_org_id() and can_edit(%L))', r.tbl, r.module);
    execute format('create policy mod_update on %I for update using (org_id = my_org_id() and can_edit(%L)) with check (org_id = my_org_id() and can_edit(%L))', r.tbl, r.module, r.module);
    execute format('create policy mod_delete on %I for delete using (org_id = my_org_id() and can_delete(%L))', r.tbl, r.module);
  end loop;
end $$;

create or replace view v_new_stock_rules as
select r.*, i.item_code, i.name as item_name, i.units_per_box, t.name as template_name,
       round(coalesce((select sum(qty_base) from stock_ledger l where l.item_id = r.item_id), 0) / nullif(i.units_per_box, 0), 3) as stock_boxes,
       (select count(*) from broadcasts b where b.item_id = r.item_id and b.kind = 'new_stock') as broadcasts
  from new_stock_rules r join items i on i.id = r.item_id left join message_templates t on t.id = r.template_id;
alter view v_new_stock_rules set (security_invoker = on);

create or replace view v_broadcasts as
select b.*, i.item_code, i.name as item_name, c.name as catalog_name, t.name as template_name, st.full_name as created_by_name,
       (select count(*) from message_log m where m.broadcast_id = b.id and m.status in ('sent', 'delivered', 'read')) as sent_count,
       (select count(*) from message_log m where m.broadcast_id = b.id and m.status = 'failed') as failed_count
  from broadcasts b
  left join items i on i.id = b.item_id
  left join catalogs c on c.id = b.catalog_id
  left join message_templates t on t.id = b.template_id
  left join staff st on st.id = b.created_by;
alter view v_broadcasts set (security_invoker = on);

/** Who a broadcast reaches: opted-in customers with a mobile, filtered by its segment. */
create or replace function broadcast_recipients(p_broadcast uuid)
returns table (customer_id uuid, name text, town text, mobile1 text, route_name text, last_bought date)
language sql stable as $$
  with b as (select * from broadcasts where id = p_broadcast)
  select c.id, c.name, c.town, c.mobile1, rt.name,
         (select max(i.invoice_date) from invoices i where i.customer_id = c.id and i.status <> 'cancelled')
    from customers c
    cross join b
    left join routes rt on rt.id = c.route_id
   where c.org_id = b.org_id and c.is_active and c.whatsapp_opt_in and normalize_mobile(c.mobile1) is not null
     and (nullif(b.segment->>'route_id', '') is null or c.route_id = (b.segment->>'route_id')::uuid)
     and (nullif(b.segment->>'town', '') is null or c.town ilike b.segment->>'town')
     and (nullif(b.segment->>'bought_within_days', '') is null or exists (
            select 1 from invoices i join invoice_items ii on ii.invoice_id = i.id
             where i.customer_id = c.id and i.status <> 'cancelled'
               and i.invoice_date >= current_date - (b.segment->>'bought_within_days')::int
               and (nullif(b.segment->>'bought_item_id', '') is null or ii.item_id = (b.segment->>'bought_item_id')::uuid)))
   order by c.town, c.name;
$$;

create or replace function queue_broadcast(p_broadcast uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b broadcasts%rowtype; rec record; v_n int := 0; v_vars jsonb; v_media text; v_purpose msg_purpose; v_id uuid;
begin
  select * into b from broadcasts where id = p_broadcast for update;
  if not found then raise exception 'Broadcast not found'; end if;
  if not is_service_call() and (b.org_id is distinct from my_org_id() or not can_edit('messaging')) then
    raise exception 'Not allowed to send this broadcast';
  end if;
  if b.status <> 'pending' then raise exception 'Broadcast is already %', b.status; end if;
  v_purpose := case b.kind when 'new_stock' then 'new_stock' when 'catalog' then 'catalog' else 'custom' end;
  v_vars := '{}'::jsonb;
  if b.item_id is not null then
    select jsonb_build_object('item', i.name, 'item_code', i.item_code) into v_vars from items i where i.id = b.item_id;
  end if;
  if b.catalog_id is not null then
    select v_vars || jsonb_build_object('catalog', c.name, 'valid_to', to_char(c.valid_to, 'DD-MM-YYYY')), c.pdf_url
      into v_vars, v_media from catalogs c where c.id = b.catalog_id;
  end if;
  for rec in select * from broadcast_recipients(p_broadcast) loop
    v_id := queue_message(jsonb_build_object('customer_id', rec.customer_id, 'purpose', v_purpose, 'template_id', b.template_id,
                                             'body', b.body, 'vars', coalesce(v_vars, '{}'::jsonb), 'media_url', v_media, 'broadcast_id', b.id));
    if v_id is not null then v_n := v_n + 1; end if;
  end loop;
  update broadcasts set status = 'queued', recipients = v_n, queued_at = now() where id = p_broadcast;
  return jsonb_build_object('broadcast_id', p_broadcast, 'queued', v_n);
end $$;

/**
 * New stock: when production or a purchase lifts an item from below its threshold to at or
 * above it, a broadcast is created for its recent buyers. auto_send queues it immediately;
 * otherwise it waits on the Messaging screen for someone to press Send.
 */
create or replace function t_new_stock_broadcast() returns trigger
language plpgsql security definer set search_path = public as $$
declare r new_stock_rules%rowtype; v_upb numeric; v_after numeric; v_before numeric; v_id uuid;
begin
  if new.txn_type not in ('production_in', 'purchase') or new.qty_base <= 0 then return null; end if;
  select * into r from new_stock_rules where org_id = new.org_id and item_id = new.item_id and is_active;
  if not found then return null; end if;
  select units_per_box into v_upb from items where id = new.item_id;
  select coalesce(sum(qty_base), 0) into v_after from stock_ledger where item_id = new.item_id;
  v_before := v_after - new.qty_base;
  if v_before < r.threshold_boxes * v_upb and v_after >= r.threshold_boxes * v_upb
     and not exists (select 1 from broadcasts b where b.item_id = new.item_id and b.kind = 'new_stock' and b.created_at > now() - interval '1 day') then
    insert into broadcasts (org_id, kind, item_id, template_id, segment, note)
    values (new.org_id, 'new_stock', new.item_id, r.template_id,
            jsonb_build_object('bought_item_id', new.item_id, 'bought_within_days', r.lookback_days),
            format('%s back in stock: %s boxes', (select item_code from items where id = new.item_id), trim(to_char(v_after / v_upb, 'FM9990.##'))))
    returning id into v_id;
    if r.auto_send then perform queue_broadcast(v_id); end if;
  end if;
  return null;
end $$;
drop trigger if exists t_new_stock_broadcast on stock_ledger;
create trigger t_new_stock_broadcast after insert on stock_ledger for each row execute function t_new_stock_broadcast();

/** Catalog or free-text push to a segment. Returns the pending broadcast id; queue_broadcast() sends it. */
create or replace function create_broadcast(p jsonb) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into broadcasts (org_id, kind, item_id, catalog_id, template_id, body, segment, note, created_by)
  values (my_org_id(), p->>'kind', nullif(p->>'item_id', '')::uuid, nullif(p->>'catalog_id', '')::uuid,
          nullif(p->>'template_id', '')::uuid, nullif(p->>'body', ''), coalesce(p->'segment', '{}'::jsonb), nullif(p->>'note', ''), my_staff_id())
  returning id into v_id;
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 7. Inbound orders. Hey Nikki posts {from, text|transcript,
--    audio_url, parsed_items:[{item_code, item_name, qty, uom,
--    confidence}]}. The operator matches, edits and converts.
-- ------------------------------------------------------------
alter table inbound_orders
  add column if not exists from_number text,
  add column if not exists transcript text,
  add column if not exists confidence numeric(4,3),
  add column if not exists provider_ref text,
  add column if not exists notes text,
  add column if not exists reject_reason text,
  add column if not exists handled_by uuid references staff(id),
  add column if not exists handled_at timestamptz;
create unique index if not exists inbound_orders_provider_idx on inbound_orders(org_id, provider_ref) where provider_ref is not null;

/** Webhook entry point (service role). Matches the org by webhook secret and the customer by mobile. */
create or replace function receive_inbound_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_from text; v_cust uuid; v_text text; v_id uuid; v_word text;
begin
  select org_id into v_org from messaging_settings where webhook_secret = p->>'secret';
  if v_org is null and is_service_call() then v_org := nullif(p->>'org_id', '')::uuid; end if;
  if v_org is null then raise exception 'Unknown webhook secret'; end if;

  v_from := normalize_mobile(p->>'from');
  if v_from is null then raise exception 'from is required'; end if;
  select id into v_cust from customers
   where org_id = v_org and is_active
     and v_from in (normalize_mobile(mobile1), normalize_mobile(mobile2), normalize_mobile(mobile3))
   order by (normalize_mobile(mobile1) = v_from) desc limit 1;

  v_text := coalesce(nullif(p->>'text', ''), nullif(p->>'transcript', ''));
  v_word := upper(regexp_replace(coalesce(v_text, ''), '[^[:alnum:]]', '', 'g'));
  if v_cust is not null and v_word in ('STOP', 'UNSUBSCRIBE', 'OPTOUT') then
    update customers set whatsapp_opt_in = false where id = v_cust;
    return jsonb_build_object('customer_id', v_cust, 'opted_out', true);
  elsif v_cust is not null and v_word in ('START', 'SUBSCRIBE', 'OPTIN') then
    update customers set whatsapp_opt_in = true where id = v_cust;
    return jsonb_build_object('customer_id', v_cust, 'opted_out', false);
  end if;

  insert into inbound_orders (org_id, customer_id, from_number, raw_text, transcript, audio_url, parsed_items, source, provider_ref, confidence)
  values (v_org, v_cust, v_from, nullif(p->>'text', ''), nullif(p->>'transcript', ''), nullif(p->>'audio_url', ''),
          case when jsonb_typeof(p->'parsed_items') = 'array' then p->'parsed_items' else '[]'::jsonb end,
          coalesce(nullif(p->>'source', '')::order_source, 'whatsapp'), nullif(p->>'provider_ref', ''),
          nullif(p->>'confidence', '')::numeric)
  on conflict (org_id, provider_ref) where provider_ref is not null do update set raw_text = inbound_orders.raw_text
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'customer_id', v_cust, 'matched', v_cust is not null);
end $$;

/** Manual entry from the screen (a phone call taken by staff). */
create or replace function create_inbound_order(p jsonb) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into inbound_orders (org_id, customer_id, from_number, raw_text, parsed_items, source, notes)
  values (my_org_id(), nullif(p->>'customer_id', '')::uuid, normalize_mobile(p->>'from'), nullif(p->>'text', ''),
          coalesce(p->'parsed_items', '[]'::jsonb), coalesce(nullif(p->>'source', '')::order_source, 'call'), nullif(p->>'notes', ''))
  returning id into v_id;
  return v_id;
end $$;

/**
 * Parsed lines matched to the item master: exact code first, then the closest name
 * (pg_trgm). Quantity is converted to boxes when the UOM is the item's unit. Anything
 * not matched by code, or below 0.7 confidence, is low_confidence for the screen to flag.
 */
/**
 * Matching what the customer said to real items. The fuzzy name match uses
 * similarity(), which belongs to pg_trgm — and Supabase keeps its extensions in a
 * schema called `extensions`, not in public. So the search_path is pinned to both:
 * a schema that does not exist is ignored, which makes this work on Supabase and on
 * a plain Postgres alike. Without it the match works from the SQL Editor, whose
 * session happens to see `extensions`, and fails from the app, whose role may not.
 */
create or replace function inbound_order_lines(p_order uuid)
returns table (idx integer, raw_code text, raw_name text, qty numeric, uom text, confidence numeric,
               item_id uuid, item_code text, item_name text, units_per_box integer, base_uom text,
               boxes numeric, rate numeric, match text, low_confidence boolean)
language sql stable set search_path = public, extensions as $$
  with o as (select * from inbound_orders where id = p_order),
  raw as (
    select x.ord::int as idx, x.e->>'item_code' as raw_code, coalesce(x.e->>'item_name', x.e->>'name') as raw_name,
           nullif(x.e->>'qty', '')::numeric as qty, x.e->>'uom' as uom, nullif(x.e->>'confidence', '')::numeric as confidence
      from o, jsonb_array_elements(coalesce(o.parsed_items, '[]'::jsonb)) with ordinality as x(e, ord)),
  m as (
    select raw.*,
           (select i.id from items i, o where i.org_id = o.org_id and i.is_active and raw.raw_code is not null
              and normalize_item_code(i.item_code) = normalize_item_code(raw.raw_code) limit 1) as by_code,
           (select i.id from items i, o where i.org_id = o.org_id and i.is_active and raw.raw_name is not null
              and similarity(i.name, raw.raw_name) >= 0.3
             order by similarity(i.name, raw.raw_name) desc limit 1) as by_name
      from raw)
  select m.idx, m.raw_code, m.raw_name, m.qty, m.uom, m.confidence,
         i.id, i.item_code, i.name, i.units_per_box, u.code,
         case when i.id is null then m.qty
              when m.uom is null or lower(m.uom) in ('box', 'boxes', 'bx', 'పెట్టె', 'పెట్టెలు') then m.qty
              when upper(m.uom) = upper(u.code) or lower(m.uom) in ('unit', 'units', 'jar', 'jars', 'pack', 'packs', 'pkt', 'pkts')
                then round(m.qty / nullif(i.units_per_box, 0), 3)
              else m.qty end,
         case when i.id is null then null
              when o.customer_id is null then i.unit_rate
              else effective_unit_rate(i.id, o.customer_id, current_date) end,
         case when m.by_code is not null then 'code' when m.by_name is not null then 'name' else 'none' end,
         m.by_code is null or coalesce(m.confidence, 1) < 0.7
    from m
    cross join o
    left join items i on i.id = coalesce(m.by_code, m.by_name)
    left join uoms u on u.id = i.base_uom_id
   order by m.idx;
$$;

/** The human step. Saves a draft invoice from the edited lines and closes the order. Never automatic. */
create or replace function convert_inbound_order(p_order uuid, p_header jsonb, p_lines jsonb) returns uuid
language plpgsql as $$
declare o inbound_orders%rowtype; v_inv uuid; v_cust uuid;
begin
  select * into o from inbound_orders where id = p_order for update;
  if not found then raise exception 'Order not found'; end if;
  if o.status not in ('new', 'confirmed') then raise exception 'Order is already %', o.status; end if;
  v_cust := (p_header->>'customer_id')::uuid;
  if v_cust is null then raise exception 'Pick the customer before converting'; end if;
  v_inv := save_invoice(p_header, p_lines);
  update inbound_orders set status = 'invoiced', invoice_id = v_inv, customer_id = v_cust,
         handled_by = my_staff_id(), handled_at = now(), notes = coalesce(nullif(p_header->>'order_notes', ''), notes)
   where id = p_order;
  perform queue_document_message('order_ack', v_cust, invoice_message_vars(v_inv), 'invoices', v_inv);
  return v_inv;
end $$;

create or replace function reject_inbound_order(p_order uuid, p_reason text default null) returns void
language plpgsql as $$
begin
  update inbound_orders set status = 'rejected', reject_reason = p_reason, handled_by = my_staff_id(), handled_at = now()
   where id = p_order and status in ('new', 'confirmed');
  if not found then raise exception 'Order not found or already handled'; end if;
end $$;

drop view if exists v_inbound_orders;
create view v_inbound_orders as
select o.id, o.org_id, o.customer_id, c.name as customer_name, c.town as customer_town, coalesce(c.mobile1, o.from_number) as mobile1,
       o.from_number, o.raw_text, o.transcript, o.audio_url, o.parsed_items,
       jsonb_array_length(coalesce(o.parsed_items, '[]'::jsonb)) as line_count,
       o.confidence, o.source, o.status, o.invoice_id, i.invoice_no, o.notes, o.reject_reason,
       o.handled_by, st.full_name as handled_by_name, o.handled_at, o.created_at
  from inbound_orders o
  left join customers c on c.id = o.customer_id
  left join invoices i on i.id = o.invoice_id
  left join staff st on st.id = o.handled_by;
alter view v_inbound_orders set (security_invoker = on);

-- Standard templates the client can accept in one click (seeded from the screen, not here).

-- Customer language (te / en) on the list view so the customer form can edit it.
create or replace view v_customer_list as
select c.id, c.org_id, c.code, c.name, c.mobile1, c.mobile2, c.mobile3, c.town, c.address,
       c.route_id, r.name as route_name, c.price_group, c.credit_limit, c.opening_balance,
       c.whatsapp_opt_in, c.is_active, c.created_at, c.price_list_id,
       coalesce(o.outstanding, 0) as outstanding,
       c.language
from customers c
left join routes r on r.id = c.route_id
left join v_customer_outstanding o on o.customer_id = c.id;
alter view v_customer_list set (security_invoker = on);
