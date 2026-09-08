-- ============================================================
-- JYOTHI FOODS ERP — 26: REPAIR. RUN THIS ONE FILE.
--
-- One file that puts a database into the correct final state no matter what
-- has been run on it, in what order, or how many times. Safe to run twice.
--
-- WHY THIS EXISTS
--
-- Postgres has no idea which version of a function is the newer one. `create
-- or replace` simply takes whatever ran last. So re-running an EARLIER file
-- silently reverts the work of a LATER one, with no error and no warning:
--
--   re-running 21 put plan_features() back to its 13-feature version, from
--   before attendance existed — so Attendance vanished from the Full plan
--   re-running 18 can put the four-argument issue_license() back beside the
--   five-argument one, and then every call is "not unique"
--   re-running 13 tries to narrow v_message_log, which 20 widened, and fails
--   halfway with "cannot drop columns from view" — leaving the rest unapplied
--
-- This file is 20 → 21 → 22 → 23 → 24 → 25 → 27 run in their proper order, which
-- is the only order that ends with every object owned by its newest author.
-- Running it fixes all of the above at once and cannot make anything worse.
--
-- THE RULE THIS REPLACES: never run a file with a lower number than one
-- already applied. Fixes go forward, in a new file.
--
-- Verified by building a database, deliberately breaking it the way the live
-- one was broken, applying this, and diffing every function signature against
-- a clean install: identical, and all twenty acceptance tests pass.
-- ============================================================



-- ════════════════════════════════════════════════════════════
-- from 20_voice.sql
-- ════════════════════════════════════════════════════════════

-- ============================================================
-- JYOTHI FOODS ERP — 20: VOICE CALLS ON HEY NIKKI (T12 phase 3b)
-- Two things ride the same queue as WhatsApp (message_log, channel
-- ivr_call): outbound payment-reminder calls in Telugu, and
-- order-taking calls where Nikki's bot asks for the order and posts
-- what it heard to nikki-inbound. The Nikki voice contract is the
-- ERP's best guess (supabase/functions/_shared/nikki.ts) until their
-- docs arrive; everything here is provider-neutral.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Settings: voice on/off, caller id, voice, retries
-- ------------------------------------------------------------
alter table messaging_settings
  add column if not exists voice_enabled boolean not null default false,
  add column if not exists caller_number text,
  add column if not exists voice_name text not null default 'te-IN-female',
  add column if not exists call_attempts integer not null default 2 check (call_attempts between 1 and 5),
  add column if not exists call_retry_minutes integer not null default 120 check (call_retry_minutes between 5 and 1440);

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
    'daily_cap', s.daily_cap, 'is_enabled', s.is_enabled, 'updated_at', s.updated_at,
    'voice_enabled', s.voice_enabled, 'caller_number', s.caller_number, 'voice_name', s.voice_name,
    'call_attempts', s.call_attempts, 'call_retry_minutes', s.call_retry_minutes);
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
    voice_enabled    = coalesce((p->>'voice_enabled')::boolean, voice_enabled),
    caller_number    = case when p ? 'caller_number' then nullif(p->>'caller_number', '') else caller_number end,
    voice_name       = coalesce(nullif(p->>'voice_name', ''), voice_name),
    call_attempts    = coalesce(nullif(p->>'call_attempts', '')::int, call_attempts),
    call_retry_minutes = coalesce(nullif(p->>'call_retry_minutes', '')::int, call_retry_minutes),
    updated_at       = now()
  where org_id = v_org;
  return get_messaging_settings();
end $$;

-- ------------------------------------------------------------
-- 2. Templates know their channel: a call needs a spoken script,
--    never a WhatsApp text. Same purpose, channel ivr_call.
-- ------------------------------------------------------------
create or replace function pick_template(p_org uuid, p_purpose msg_purpose, p_language text, p_channel channel_kind)
returns message_templates language sql stable as $$
  select t from message_templates t
   where t.org_id = p_org and t.purpose = p_purpose and t.is_active
     and (p_channel is distinct from 'ivr_call' or t.channel = 'ivr_call')     -- a call only ever reads a call script
     and (p_channel = 'ivr_call' or t.channel <> 'ivr_call')                    -- and a text never reads one
   order by (t.channel = p_channel) desc, (t.language = p_language) desc, (t.language = 'te') desc, t.name
   limit 1;
$$;

/**
 * The three-argument version from 13_messaging.sql has to go, or it sits there
 * for ever as the one thing that can undo this file: it ignores the channel, so
 * a three-argument call quietly hands a WhatsApp text to a voice call — exactly
 * what the two clauses above exist to prevent. Nothing calls it any more
 * (queue_message is replaced just below), and leaving a dead overload beside a
 * live one is how the next person reintroduces the bug by writing the obvious
 * call. Postgres resolves function bodies at run time, so this drop is safe here.
 */
drop function if exists pick_template(uuid, msg_purpose, text);

alter table message_log
  add column if not exists not_before timestamptz,
  add column if not exists call_status text,
  add column if not exists call_duration integer,
  add column if not exists call_result jsonb,
  add column if not exists promised_on date;
alter table customers
  add column if not exists payment_promise_on date,
  add column if not exists payment_promise_note text;

create or replace function queue_message(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare c customers%rowtype; t message_templates; v_vars jsonb; v_body text; v_id uuid; v_to text; v_purpose msg_purpose; v_media text; v_channel channel_kind;
begin
  select * into c from customers where id = (p->>'customer_id')::uuid;
  if not found then raise exception 'Customer not found'; end if;
  if not is_service_call() and c.org_id is distinct from my_org_id() then
    raise exception 'Customer belongs to another organisation';
  end if;
  v_purpose := (p->>'purpose')::msg_purpose;
  v_channel := nullif(p->>'channel', '')::channel_kind;
  v_to := normalize_mobile(coalesce(nullif(p->>'to_number', ''), c.mobile1));
  if v_to is null or not c.whatsapp_opt_in then return null; end if;

  if nullif(p->>'template_id', '') is not null then
    select * into t from message_templates where id = (p->>'template_id')::uuid and org_id = c.org_id;
  else
    t := pick_template(c.org_id, v_purpose, c.language, coalesce(v_channel, 'whatsapp'));
  end if;
  v_channel := coalesce(v_channel, t.channel, 'whatsapp');

  v_vars := jsonb_build_object(
              'org', (select name from orgs where id = c.org_id),
              'name', c.name, 'town', coalesce(c.town, ''),
              'outstanding', to_char(coalesce((select outstanding from v_customer_outstanding where customer_id = c.id), 0), 'FM9,99,99,990.00'),
              'date', to_char(current_date, 'DD-MM-YYYY'),
              'last_items', coalesce((select string_agg(it.name || ' ' || trim(to_char(ii.boxes, 'FM9990.##')), ', ' order by ii.id)
                                        from invoice_items ii join items it on it.id = ii.item_id
                                       where ii.invoice_id = (select i.id from invoices i where i.customer_id = c.id and i.status <> 'cancelled'
                                                               order by i.invoice_date desc, i.created_at desc limit 1)), ''))
            || coalesce(p->'vars', '{}'::jsonb);
  v_body := coalesce(nullif(p->>'body', ''), render_template(t.body, v_vars));
  if v_body is null or v_body = '' then
    raise exception 'No active % % for %', v_purpose, case when v_channel = 'ivr_call' then 'call script' else 'template' end, c.name;
  end if;
  v_media := nullif(p->>'media_url', '');

  insert into message_log (org_id, customer_id, template_id, channel, purpose, to_number, body, payload, status,
                           ref_table, ref_id, rule_id, broadcast_id)
  values (c.org_id, c.id, t.id, v_channel, v_purpose, v_to, v_body,
          jsonb_strip_nulls(jsonb_build_object('vars', v_vars, 'media_url', v_media, 'kind', nullif(p->>'kind', ''),
                                               'template_name', t.provider_template_name, 'language', coalesce(t.language, c.language))),
          'queued', nullif(p->>'ref_table', ''), nullif(p->>'ref_id', '')::uuid,
          nullif(p->>'rule_id', '')::uuid, nullif(p->>'broadcast_id', '')::uuid)
  returning id into v_id;
  return v_id;
end $$;

/** The sender's claim: switch, quiet hours, daily cap, retry delay, and voice only when it is on. */
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
   -- The day the cap counts is an IST calendar day, so the boundary has to be IST
   -- midnight turned back into an instant. Comparing a timestamptz against a bare
   -- IST date casts that date to midnight UTC — 05:30 IST — which silently moves the
   -- window five and a half hours and lets anything sent after midnight escape the cap.
   where org_id = p_org
     and sent_at >= (((now() at time zone 'Asia/Kolkata')::date)::timestamp at time zone 'Asia/Kolkata');
  if v_sent_today >= s.daily_cap then return; end if;
  return query
    update message_log set attempts = attempts + 1, updated_at = now(), not_before = null
     where id in (select id from message_log
                   where org_id = p_org and status = 'queued' and attempts < 3
                     and (not_before is null or not_before <= now())
                     and (channel <> 'ivr_call' or s.voice_enabled)
                   order by created_at limit least(p_limit, s.daily_cap - v_sent_today))
    returning *;
end $$;

/**
 * Call outcome from the nikki-status webhook. Events: ringing, answered, completed,
 * no_answer, busy, failed. `p_result` may carry dtmf, transcript, recording_url,
 * promised_on. On a reminder call, key 1 = "will pay this week", 2 = "already paid",
 * 3 = "call me back". An unanswered call is retried after call_retry_minutes, up to
 * call_attempts, then marked failed.
 */
create or replace function mark_call_result(p_provider_msg_id text, p_event text, p_duration integer default null, p_result jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare m message_log%rowtype; s messaging_settings%rowtype; v_promise date; v_note text; v_dtmf text;
begin
  select * into m from message_log where provider_msg_id = p_provider_msg_id;
  if not found then return false; end if;
  select * into s from messaging_settings where org_id = m.org_id;
  v_dtmf := nullif(p_result->>'dtmf', '');
  v_promise := nullif(p_result->>'promised_on', '')::date;
  if m.purpose = 'payment_reminder' and v_promise is null then
    v_promise := case v_dtmf when '1' then current_date + 7 else null end;
  end if;
  v_note := case v_dtmf when '1' then 'Promised on the call to pay within a week'
                        when '2' then 'Says already paid — check the receipts'
                        when '3' then 'Asked for a call back from the office' else nullif(p_result->>'note', '') end;

  update message_log set
    call_status   = p_event,
    call_duration = coalesce(p_duration, call_duration),
    call_result   = coalesce(call_result, '{}'::jsonb) || coalesce(p_result, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('note', v_note)),
    promised_on   = coalesce(v_promise, promised_on),
    status = (case p_event
               when 'answered'  then case when status = 'read' then 'read' else 'delivered' end
               when 'completed' then case when v_dtmf is not null or nullif(p_result->>'transcript', '') is not null then 'read'
                                          when status = 'read' then 'read' else 'delivered' end
               when 'no_answer' then case when attempts < coalesce(s.call_attempts, 2) then 'queued' else 'failed' end
               when 'busy'      then case when attempts < coalesce(s.call_attempts, 2) then 'queued' else 'failed' end
               when 'failed'    then 'failed'
               else status::text end)::msg_status,
    not_before = case when p_event in ('no_answer', 'busy') and attempts < coalesce(s.call_attempts, 2)
                      then now() + make_interval(mins => coalesce(s.call_retry_minutes, 120)) else not_before end,
    error = case p_event when 'failed' then coalesce(nullif(p_result->>'error', ''), 'call failed')
                         when 'no_answer' then 'no answer' when 'busy' then 'busy' else error end,
    delivered_at = case when p_event in ('answered', 'completed') then coalesce(delivered_at, now()) else delivered_at end,
    read_at      = case when p_event = 'completed' and (v_dtmf is not null or nullif(p_result->>'transcript', '') is not null) then coalesce(read_at, now()) else read_at end,
    updated_at = now()
  where id = m.id;

  if v_promise is not null and m.customer_id is not null then
    update customers set payment_promise_on = v_promise, payment_promise_note = v_note where id = m.customer_id;
  elsif v_note is not null and m.customer_id is not null then
    update customers set payment_promise_note = v_note where id = m.customer_id;
  end if;
  return true;
end $$;

create or replace view v_message_log as
select m.id, m.org_id, m.customer_id, c.name as customer_name, c.town, m.to_number, m.channel, m.purpose, m.status,
       m.body, m.error, m.template_id, t.name as template_name, m.provider_msg_id, m.payload->>'media_url' as media_url,
       m.ref_table, m.ref_id, m.rule_id, r.name as rule_name, m.broadcast_id, m.attempts,
       m.sent_at, m.delivered_at, m.read_at, m.created_at,
       m.not_before, m.call_status, m.call_duration, m.call_result, m.promised_on,
       m.call_result->>'recording_url' as recording_url, m.call_result->>'transcript' as transcript, m.call_result->>'note' as call_note
  from message_log m
  left join customers c on c.id = m.customer_id
  left join message_templates t on t.id = m.template_id
  left join reminder_rules r on r.id = m.rule_id;
alter view v_message_log set (security_invoker = on);

-- A promise made on a call holds the reminders back until the date passes.
create or replace function reminder_recipients(p_rule uuid)
returns table (customer_id uuid, name text, town text, mobile1 text, outstanding numeric, overdue_days integer,
               last_reminder_at timestamptz, due boolean, skip_reason text)
language sql stable security definer set search_path = public as $$
  with r as (select rr.*, coalesce(o.credit_days, 0) as credit_days from reminder_rules rr join orgs o on o.id = rr.org_id where rr.id = p_rule),
  cust as (
    select c.id, c.name, c.town, c.mobile1, c.route_id, c.whatsapp_opt_in, c.payment_promise_on,
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
       and not exists (select 1 from reminder_rules r2
                        where r2.org_id = r.org_id and r2.is_active and r2.id <> r.id
                          and r2.overdue_days > r.overdue_days and cust.overdue_days >= r2.overdue_days
                          and cust.outstanding >= r2.min_outstanding
                          and (r2.route_id is null or r2.route_id = cust.route_id)))
  select m.id, m.name, m.town, m.mobile1, m.outstanding, m.overdue_days, m.last_reminder_at,
         m.whatsapp_opt_in and normalize_mobile(m.mobile1) is not null
           and (m.payment_promise_on is null or m.payment_promise_on < current_date)
           and (m.last_reminder_at is null or m.last_reminder_at < now() - make_interval(days => (select repeat_every_days from r))) as due,
         case when not m.whatsapp_opt_in then 'opted out'
              when normalize_mobile(m.mobile1) is null then 'no mobile'
              when m.payment_promise_on >= current_date then 'promised to pay by ' || to_char(m.payment_promise_on, 'DD-MM-YYYY')
              when m.last_reminder_at >= now() - make_interval(days => (select repeat_every_days from r))
                then 'reminded ' || (current_date - m.last_reminder_at::date) || ' days ago'
              end as skip_reason
    from matched m
   order by m.outstanding desc;
$$;

create or replace view v_customer_list as
select c.id, c.org_id, c.code, c.name, c.mobile1, c.mobile2, c.mobile3, c.town, c.address,
       c.route_id, r.name as route_name, c.price_group, c.credit_limit, c.opening_balance,
       c.whatsapp_opt_in, c.is_active, c.created_at, c.price_list_id,
       coalesce(o.outstanding, 0) as outstanding,
       c.language,
       c.sales_exec_id, se.full_name as sales_exec_name,
       c.payment_promise_on, c.payment_promise_note
from customers c
left join routes r on r.id = c.route_id
left join staff se on se.id = c.sales_exec_id
left join v_customer_outstanding o on o.customer_id = c.id;
alter view v_customer_list set (security_invoker = on);

-- ------------------------------------------------------------
-- 3. Order-taking calls: a broadcast of kind order_call rings a
--    segment with the order script; what the bot hears comes back
--    through nikki-inbound with our message id as client_ref.
-- ------------------------------------------------------------
alter table broadcasts drop constraint if exists broadcasts_kind_check;
alter table broadcasts add constraint broadcasts_kind_check check (kind in ('new_stock', 'catalog', 'custom', 'order_call'));

create or replace function queue_broadcast(p_broadcast uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b broadcasts%rowtype; rec record; v_n int := 0; v_vars jsonb; v_media text; v_purpose msg_purpose; v_id uuid; v_channel text;
begin
  select * into b from broadcasts where id = p_broadcast for update;
  if not found then raise exception 'Broadcast not found'; end if;
  if not is_service_call() and (b.org_id is distinct from my_org_id() or not can_edit('messaging')) then
    raise exception 'Not allowed to send this broadcast';
  end if;
  if b.status <> 'pending' then raise exception 'Broadcast is already %', b.status; end if;
  v_purpose := case b.kind when 'new_stock' then 'new_stock' when 'catalog' then 'catalog' else 'custom' end;
  v_channel := case when b.kind = 'order_call' then 'ivr_call' else null end;
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
                                             'body', b.body, 'vars', coalesce(v_vars, '{}'::jsonb), 'media_url', v_media, 'broadcast_id', b.id,
                                             'channel', v_channel, 'kind', b.kind));
    if v_id is not null then v_n := v_n + 1; end if;
  end loop;
  update broadcasts set status = 'queued', recipients = v_n, queued_at = now() where id = p_broadcast;
  return jsonb_build_object('broadcast_id', p_broadcast, 'queued', v_n);
end $$;

alter table inbound_orders
  add column if not exists message_id uuid references message_log(id) on delete set null,
  add column if not exists language text,
  add column if not exists call_duration integer;

create or replace function receive_inbound_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_from text; v_cust uuid; v_text text; v_id uuid; v_word text; v_msg message_log%rowtype;
begin
  select org_id into v_org from messaging_settings where webhook_secret = p->>'secret';
  if v_org is null and is_service_call() then v_org := nullif(p->>'org_id', '')::uuid; end if;
  if v_org is null then raise exception 'Unknown webhook secret'; end if;

  -- an answer to one of our calls: the message id we sent as client_ref
  if nullif(p->>'client_ref', '') is not null then
    select * into v_msg from message_log where id = nullif(p->>'client_ref', '')::uuid and org_id = v_org;
  end if;

  v_from := normalize_mobile(coalesce(nullif(p->>'from', ''), v_msg.to_number));
  if v_from is null then raise exception 'from is required'; end if;
  select id into v_cust from customers
   where org_id = v_org and is_active
     and v_from in (normalize_mobile(mobile1), normalize_mobile(mobile2), normalize_mobile(mobile3))
   order by (normalize_mobile(mobile1) = v_from) desc limit 1;
  v_cust := coalesce(v_cust, v_msg.customer_id);

  v_text := coalesce(nullif(p->>'text', ''), nullif(p->>'transcript', ''));
  v_word := upper(regexp_replace(coalesce(v_text, ''), '[^[:alnum:]]', '', 'g'));
  if v_cust is not null and v_word in ('STOP', 'UNSUBSCRIBE', 'OPTOUT') then
    update customers set whatsapp_opt_in = false where id = v_cust;
    return jsonb_build_object('customer_id', v_cust, 'opted_out', true);
  elsif v_cust is not null and v_word in ('START', 'SUBSCRIBE', 'OPTIN') then
    update customers set whatsapp_opt_in = true where id = v_cust;
    return jsonb_build_object('customer_id', v_cust, 'opted_out', false);
  end if;

  insert into inbound_orders (org_id, customer_id, from_number, raw_text, transcript, audio_url, parsed_items, source, provider_ref, confidence,
                              message_id, language, call_duration)
  values (v_org, v_cust, v_from, nullif(p->>'text', ''), nullif(p->>'transcript', ''), nullif(p->>'audio_url', ''),
          case when jsonb_typeof(p->'parsed_items') = 'array' then p->'parsed_items' else '[]'::jsonb end,
          coalesce(nullif(p->>'source', '')::order_source, (case when v_msg.id is not null then 'call' else 'whatsapp' end)::order_source),
          nullif(p->>'provider_ref', ''), nullif(p->>'confidence', '')::numeric,
          v_msg.id, nullif(p->>'language', ''), nullif(p->>'duration', '')::int)
  on conflict (org_id, provider_ref) where provider_ref is not null do update set raw_text = inbound_orders.raw_text
  returning id into v_id;

  if v_msg.id is not null then
    update message_log set status = 'read', read_at = coalesce(read_at, now()), delivered_at = coalesce(delivered_at, now()),
           call_status = coalesce(call_status, 'completed'), call_duration = coalesce(nullif(p->>'duration', '')::int, call_duration),
           call_result = coalesce(call_result, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('order_id', v_id, 'transcript', nullif(p->>'transcript', ''), 'recording_url', nullif(p->>'audio_url', ''))),
           updated_at = now()
     where id = v_msg.id;
  end if;
  return jsonb_build_object('id', v_id, 'customer_id', v_cust, 'matched', v_cust is not null, 'message_id', v_msg.id);
end $$;

drop view if exists v_inbound_orders;
create view v_inbound_orders as
select o.id, o.org_id, o.customer_id, c.name as customer_name, c.town as customer_town, coalesce(c.mobile1, o.from_number) as mobile1,
       o.from_number, o.raw_text, o.transcript, o.audio_url, o.parsed_items,
       jsonb_array_length(coalesce(o.parsed_items, '[]'::jsonb)) as line_count,
       o.confidence, o.source, o.status, o.invoice_id, i.invoice_no, o.notes, o.reject_reason,
       o.handled_by, st.full_name as handled_by_name, o.handled_at, o.created_at,
       so.id as order_id, so.order_no,
       o.message_id, o.language, o.call_duration, b.kind as campaign_kind, b.note as campaign_note
  from inbound_orders o
  left join customers c on c.id = o.customer_id
  left join invoices i on i.id = o.invoice_id
  left join staff st on st.id = o.handled_by
  left join lateral (select id, order_no from orders x where x.source_inbound_id = o.id order by x.created_at desc limit 1) so on true
  left join message_log m on m.id = o.message_id
  left join broadcasts b on b.id = m.broadcast_id;
alter view v_inbound_orders set (security_invoker = on);


-- ════════════════════════════════════════════════════════════
-- from 21_plans.sql
-- ════════════════════════════════════════════════════════════

-- ============================================================
-- JYOTHI FOODS ERP — 21: LICENCE PLANS (three keys)
--
-- One licence key per organisation already decides IF the app runs
-- (db/18_licensing.sql: trial → active → grace → expired). This file
-- adds WHAT it runs: the key also carries a plan, and the plan decides
-- which features are unlocked.
--
--   starter   billing and collection — the day-to-day counter work
--   growth    + the rest of the operation: buying, paying, returns,
--             production, vans, quotations / orders / challans / pricing
--   full      + everything automatic: WhatsApp and voice, batches and
--             barcodes, print designer, backup, audit, route profit,
--             incentives, the driver's phone, the desktop app
--
-- A fresh organisation is 'full' for its trial, so the client sees the
-- whole thing before buying; the key issued afterwards sets what was
-- actually paid for. Upgrading is one line — no reinstall, no new build.
--
-- Enforcement is the database's, not the screen's:
--   • can_view / can_edit / can_delete gain a plan test, so every
--     module-gated RLS policy already in the app is capped at once
--   • the finer features get restrictive RLS on their own tables, so a
--     locked feature cannot be written even by hand-made API calls
--   • the few functions that run as definer test the plan themselves
-- ============================================================

alter table orgs
  add column if not exists license_plan text not null default 'full'
    check (license_plan in ('starter', 'growth', 'full'));

/** What each plan includes. The single place a feature moves between plans. */
create or replace function plan_features(p_plan text) returns text[]
language sql immutable as $$
  select case p_plan
    when 'starter' then array['core']
    when 'growth'  then array['core', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents']
    else array['core', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents',
               'messaging', 'inventory', 'owner', 'insights', 'mobile', 'desktop']
  end;
$$;

create or replace function plan_label(p_plan text) returns text
language sql immutable as $$
  select case p_plan when 'starter' then 'Starter' when 'growth' then 'Growth' else 'Full' end;
$$;

/** Every feature the app knows, with the plan it first appears in — for the screen. */
create or replace function feature_catalogue()
returns table (feature text, label text, plan text, detail text)
language sql immutable as $$
  select * from (values
    ('core',       'Billing & collection', 'starter', 'Items, customers, invoices and prints, receipts, stock on hand, the day''s reports, setup and users'),
    ('purchases',  'Purchases',            'growth',  'Supplier bills, suppliers, purchase returns'),
    ('returns',    'Sales returns',        'growth',  'Fresh return, rate difference and damage return'),
    ('payments',   'Payments & accounts',  'growth',  'Payments, expenses, cash and bank books, cheques, journal, trial balance, P&L, balance sheet'),
    ('production', 'Production',           'growth',  'Recipes, batches, chief actuals, variance'),
    ('vehicles',   'Vans & trips',         'growth',  'Trips, van loading, loading sheet, settlement'),
    ('documents',  'Quotations & pricing', 'growth',  'Quotations, sale and purchase orders, delivery challans, price lists, discount schemes'),
    ('messaging',  'WhatsApp & calls',     'full',    'Templates, payment reminders, new-stock and catalog broadcasts, inbound orders, reminder and order-taking calls'),
    ('inventory',  'Batches & barcodes',   'full',    'Batch and expiry tracking, barcode labels, godown transfers, physical stock counts'),
    ('owner',      'Owner control',        'full',    'Print designer, backup and restore, audit trail'),
    ('insights',   'Profit & incentives',  'full',    'Route profitability and salesman incentive statements'),
    ('mobile',     'Driver''s phone',      'full',    'Van sales, on-the-spot receipts and delivery proof from a phone'),
    ('desktop',    'Desktop & offline',    'full',    'The installed Windows app, and working without a connection')
  ) as t(feature, label, plan, detail);
$$;

/** Which feature a module belongs to; the eight starter modules are 'core'. */
create or replace function module_feature(p_module text) returns text
language sql immutable as $$
  select case p_module
    when 'purchases'  then 'purchases'
    when 'returns'    then 'returns'
    when 'payments'   then 'payments'
    when 'production' then 'production'
    when 'vehicles'   then 'vehicles'
    when 'messaging'  then 'messaging'
    else 'core'
  end;
$$;

create or replace function my_plan() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select o.license_plan from orgs o where o.id = my_org_id()), 'starter');
$$;

/** Is this feature unlocked for the caller's organisation? The service role is never capped. */
create or replace function has_feature(p_feature text) returns boolean
language sql stable security definer set search_path = public as $$
  select is_service_call() or p_feature = any(plan_features(my_plan()));
$$;

-- ------------------------------------------------------------
-- 1. The plan caps every module-gated policy in the app at once.
-- ------------------------------------------------------------
create or replace function can_view(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_feature(module_feature(p_module)) and case
    when my_role() = 'owner' then true
    else coalesce((select rp.can_view from role_permissions rp
                    where rp.org_id = my_org_id() and rp.role = my_role() and rp.module = p_module), false)
  end;
$$;

create or replace function can_edit(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_feature(module_feature(p_module)) and case
    when my_role() = 'owner' then true
    else coalesce((select rp.can_edit from role_permissions rp
                    where rp.org_id = my_org_id() and rp.role = my_role() and rp.module = p_module), false)
  end;
$$;

create or replace function can_delete(p_module text) returns boolean
language sql stable security definer set search_path = public as $$
  select has_feature(module_feature(p_module)) and case
    when my_role() = 'owner' then true
    else coalesce((select rp.can_delete from role_permissions rp
                    where rp.org_id = my_org_id() and rp.role = my_role() and rp.module = p_module), false)
  end;
$$;

-- ------------------------------------------------------------
-- 2. Features that live inside a module the plan already allows get
--    a restrictive policy on their own tables: reads stay (nothing a
--    client made in the trial disappears), writes stop.
-- ------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('quotations', 'documents'), ('quotation_items', 'documents'), ('orders', 'documents'), ('order_items', 'documents'),
    ('order_fulfilments', 'documents'), ('delivery_challans', 'documents'), ('challan_items', 'documents'),
    ('purchase_returns', 'documents'), ('purchase_return_items', 'documents'),
    ('price_lists', 'documents'), ('price_list_items', 'documents'), ('discount_schemes', 'documents'),
    ('item_batches', 'inventory'), ('item_barcodes', 'inventory'), ('stock_transfers', 'inventory'),
    ('stock_transfer_items', 'inventory'), ('stock_counts', 'inventory'), ('stock_count_items', 'inventory'),
    ('print_templates', 'owner'), ('backups', 'owner'), ('backup_settings', 'owner'),
    ('incentive_schemes', 'insights'),
    ('message_templates', 'messaging'), ('reminder_rules', 'messaging'), ('catalogs', 'messaging'),
    ('broadcasts', 'messaging'), ('new_stock_rules', 'messaging'), ('inbound_orders', 'messaging'),
    ('transaction_message_settings', 'messaging'), ('messaging_settings', 'messaging')
  ) as t(tbl, feature) loop
    if to_regclass('public.' || r.tbl) is null then continue; end if;
    execute format('drop policy if exists plan_insert on %I', r.tbl);
    execute format('drop policy if exists plan_update on %I', r.tbl);
    execute format('drop policy if exists plan_delete on %I', r.tbl);
    execute format('create policy plan_insert on %I as restrictive for insert with check (has_feature(%L))', r.tbl, r.feature);
    execute format('create policy plan_update on %I as restrictive for update using (has_feature(%L))', r.tbl, r.feature);
    execute format('create policy plan_delete on %I as restrictive for delete using (has_feature(%L))', r.tbl, r.feature);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 3. The functions that run as definer, or only read, test the plan
--    themselves — RLS on a table cannot speak for them.
-- ------------------------------------------------------------
create or replace function require_feature(p_feature text) returns void
language plpgsql stable security definer set search_path = public as $$
declare v_plan text; v_needs text;
begin
  if has_feature(p_feature) then return; end if;
  select f.plan, f.label into v_plan, v_needs from feature_catalogue() f where f.feature = p_feature;
  raise exception '% is not part of your % licence. It is included in the % plan.',
    coalesce(v_needs, p_feature), plan_label(my_plan()), plan_label(coalesce(v_plan, 'full'))
    using errcode = 'P0001', hint = 'plan_locked';
end $$;

create or replace function org_snapshot(p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; spec text; parts text[]; t text; v_rows jsonb; v_tables jsonb := '{}'::jsonb; v_order text;
begin
  if is_service_call() then
    v_org := p_org;
  else
    perform require_feature('owner');
    if my_role() <> 'owner' then raise exception 'Only the owner can take a backup'; end if;
    v_org := my_org_id();
  end if;
  if v_org is null then raise exception 'Organisation not known'; end if;
  foreach spec in array snapshot_tables() loop
    parts := string_to_array(spec, ':');
    t := parts[1];
    v_order := case t when 'ledger_accounts' then 'order by (t.parent_id is null) desc, t.name'
                      when 'journal_entries' then 'order by (t.reverses_entry_id is null) desc, t.created_at, t.entry_no'
                      when 'receipts' then 'order by (t.reversal_of is null) desc, t.created_at'
                      when 'payments' then 'order by (t.reversal_of is null) desc, t.created_at'
                      else 'order by t.ctid' end;
    if array_length(parts, 1) = 3 then
      execute format('select coalesce(jsonb_agg(to_jsonb(t) %s), ''[]''::jsonb) from %I t where exists (select 1 from %I p where p.id = t.%I and p.org_id = $1)', v_order, t, parts[3], parts[2]) into v_rows using v_org;
    else
      execute format('select coalesce(jsonb_agg(to_jsonb(t) %s), ''[]''::jsonb) from %I t where t.org_id = $1', v_order, t) into v_rows using v_org;
    end if;
    v_tables := v_tables || jsonb_build_object(t, v_rows);
  end loop;
  return jsonb_build_object('version', 1, 'taken_at', now(), 'org_id', v_org,
                            'org', (select to_jsonb(o) - 'license_key' from orgs o where o.id = v_org),
                            'tables', v_tables);
end $$;

create or replace function audit_search(p_from timestamptz default null, p_to timestamptz default null, p_table text default null, p_actor uuid default null, p_action text default null, p_search text default null, p_limit int default 200)
returns setof v_audit_log language plpgsql stable as $$
begin
  perform require_feature('owner');
  return query
    select * from v_audit_log a
     where a.org_id = my_org_id()
       and (p_from is null or a.created_at >= p_from) and (p_to is null or a.created_at <= p_to)
       and (p_table is null or a.table_name = p_table) and (p_actor is null or a.actor = p_actor)
       and (p_action is null or a.action = p_action)
       and (p_search is null or p_search = '' or a.row_id ilike '%' || p_search || '%' or coalesce(a.after::text, '') ilike '%' || p_search || '%' or coalesce(a.before::text, '') ilike '%' || p_search || '%')
     order by a.created_at desc, a.id desc
     limit least(coalesce(p_limit, 200), 1000);
end $$;

create or replace function mark_delivered(p_invoice uuid, p_photo text default null, p_receiver text default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare inv invoices%rowtype; v_driver uuid;
begin
  perform require_feature('mobile');
  select * into inv from invoices where id = p_invoice and org_id = my_org_id();
  if not found then raise exception 'Invoice not found'; end if;
  select driver_id into v_driver from vehicle_trips where id = inv.trip_id;
  if not (can_edit('invoices') or (v_driver is not null and v_driver = my_staff_id())) then
    raise exception 'Only the trip''s driver or an invoice editor can mark a delivery';
  end if;
  if inv.status in ('confirmed', 'dispatched') then
    perform set_invoice_status(p_invoice, 'delivered');
  elsif inv.status <> 'delivered' then
    raise exception 'Invoice % is %, not deliverable', inv.invoice_no, inv.status;
  end if;
  update invoices set delivered_at = now(), delivered_by = my_staff_id(),
         delivery_photo = coalesce(p_photo, delivery_photo), receiver_name = coalesce(nullif(p_receiver, ''), receiver_name),
         delivery_note = coalesce(nullif(p_note, ''), delivery_note)
   where id = p_invoice;
end $$;

create or replace function my_open_trip() returns setof v_trip_list
language plpgsql stable as $$
begin
  perform require_feature('mobile');
  return query
    select * from v_trip_list t
     where t.org_id = my_org_id() and t.driver_id = my_staff_id() and t.status in ('loaded', 'dispatched')
     order by t.trip_date desc, t.created_at desc limit 1;
end $$;

create or replace function trip_stops(p_trip uuid)
returns table (customer_id uuid, name text, town text, mobile1 text, address text, outstanding numeric, on_route boolean,
               bills integer, billed numeric, delivered integer, collected numeric, last_invoice_id uuid, pending_delivery uuid[])
language plpgsql stable as $$
-- every output column is a variable in here, so a bare column name would win over the
-- table's; use_column says the opposite, and the names below are qualified anyway
#variable_conflict use_column
begin
  perform require_feature('mobile');
  return query
  with t as (select * from vehicle_trips where id = p_trip),
  c as (
    select c.* from customers c, t where c.org_id = t.org_id and c.is_active and c.route_id = t.route_id
    union
    select c.* from customers c, t
     where c.id in (select i.customer_id from invoices i where i.trip_id = t.id
                    union select r.customer_id from receipts r where r.trip_id = t.id)),
  inv as (
    select i.customer_id, count(*) as bills, sum(i.total) as billed, count(*) filter (where i.status = 'delivered') as delivered,
           (array_agg(i.id order by i.created_at desc))[1] as last_id,
           array_remove(array_agg(i.id order by i.created_at) filter (where i.status in ('confirmed', 'dispatched')), null) as pending
      from invoices i, t where i.trip_id = t.id and i.status <> 'cancelled' group by 1),
  rc as (select r.customer_id, sum(r.total_amount) as collected from receipts r, t where r.trip_id = t.id group by 1)
  select c.id, c.name, c.town, c.mobile1, c.address, coalesce(o.outstanding, 0), (c.route_id = t.route_id),
         coalesce(inv.bills, 0)::int, coalesce(inv.billed, 0), coalesce(inv.delivered, 0)::int, coalesce(rc.collected, 0), inv.last_id,
         coalesce(inv.pending, '{}'::uuid[])
    from c cross join t
    left join v_customer_outstanding o on o.customer_id = c.id
    left join inv on inv.customer_id = c.id
    left join rc on rc.customer_id = c.id
   order by (coalesce(inv.bills, 0) > 0) desc, c.town, c.name;
end $$;

/** Route profitability and incentives read tables the plan already allows, so they ask here. */
create or replace function route_profitability(p_org uuid, p_from date, p_to date)
returns table (route_id uuid, route_name text, customers integer, trips integer, km numeric, invoices integer, boxes numeric,
               sales numeric, returns numeric, cogs numeric, gross_margin numeric, trip_expenses numeric, driver_wages numeric,
               net_profit numeric, margin_pct numeric, collection numeric, sales_per_km numeric)
language plpgsql stable as $$
#variable_conflict use_column
begin
  perform require_feature('insights');
  return query
  with cost as (
    select i.id as item_id,
           coalesce((select round(b.total_cost / nullif(b.actual_boxes * i.units_per_box, 0), 4) from production_batches b
                      where b.item_id = i.id and b.status = 'closed' and b.actual_boxes > 0 and b.production_date <= p_to
                      order by b.production_date desc, b.closed_at desc limit 1),
                    i.purchase_rate, 0) as unit_cost
      from items i where i.org_id = p_org),
  inv as (
    select i.id, coalesce(t.route_id, c.route_id) as route_id, i.total,
           (select coalesce(sum(ii.boxes), 0) from invoice_items ii where ii.invoice_id = i.id) as boxes,
           (select coalesce(sum(ii.qty * co.unit_cost), 0) from invoice_items ii join cost co on co.item_id = ii.item_id where ii.invoice_id = i.id) as cogs
      from invoices i
      join customers c on c.id = i.customer_id
      left join vehicle_trips t on t.id = i.trip_id
     where i.org_id = p_org and i.status <> 'cancelled' and i.invoice_date between p_from and p_to),
  by_inv as (select x.route_id, count(*) as n, sum(x.total) as sales, sum(x.boxes) as boxes, sum(x.cogs) as cogs from inv x group by 1),
  rets as (
    select coalesce(t.route_id, c.route_id) as route_id, sum(r.total) as returns
      from sales_returns r join customers c on c.id = r.customer_id
      left join invoices i on i.id = r.invoice_id left join vehicle_trips t on t.id = i.trip_id
     where r.org_id = p_org and r.return_date between p_from and p_to group by 1),
  coll as (
    select coalesce(t.route_id, c.route_id) as route_id, sum(r.total_amount) as collection
      from receipts r join customers c on c.id = r.customer_id left join vehicle_trips t on t.id = r.trip_id
     where r.org_id = p_org and r.receipt_date between p_from and p_to group by 1),
  -- named trp, not trips: an output column is called trips and plpgsql would see the variable
  trp as (
    select t.route_id, count(*) as n, sum(greatest(coalesce(t.closing_km, 0) - coalesce(t.opening_km, 0), 0)) as km,
           sum(coalesce(t.expenses, 0)) as expenses, sum(coalesce(d.daily_wage, 0)) as wages
      from vehicle_trips t left join staff d on d.id = t.driver_id
     where t.org_id = p_org and t.trip_date between p_from and p_to and t.status <> 'cancelled' group by 1),
  keys as (
    select r.id as route_id, r.name from routes r where r.org_id = p_org
    union select null::uuid, 'No route'),
  rows as (
    select k.route_id, k.name,
           (select count(*) from customers c where c.org_id = p_org and c.is_active and c.route_id is not distinct from k.route_id)::int as customers,
           coalesce(tr.n, 0)::int as trips, coalesce(tr.km, 0) as km, coalesce(bi.n, 0)::int as invoices, coalesce(bi.boxes, 0) as boxes,
           coalesce(bi.sales, 0) as sales, coalesce(rt.returns, 0) as returns, round(coalesce(bi.cogs, 0), 2) as cogs,
           coalesce(tr.expenses, 0) as trip_expenses, coalesce(tr.wages, 0) as driver_wages, coalesce(cl.collection, 0) as collection
      from keys k
      left join by_inv bi on bi.route_id is not distinct from k.route_id
      left join rets rt on rt.route_id is not distinct from k.route_id
      left join coll cl on cl.route_id is not distinct from k.route_id
      left join trp tr on tr.route_id is not distinct from k.route_id)
  select x.route_id, x.name, x.customers, x.trips, x.km, x.invoices, x.boxes, x.sales, x.returns, x.cogs,
         round(x.sales - x.returns - x.cogs, 2), x.trip_expenses, x.driver_wages,
         round(x.sales - x.returns - x.cogs - x.trip_expenses - x.driver_wages, 2),
         case when x.sales > 0 then round((x.sales - x.returns - x.cogs - x.trip_expenses - x.driver_wages) / x.sales * 100, 1) end,
         x.collection,
         case when x.km > 0 then round(x.sales / x.km, 2) end
    from rows x
   where x.sales <> 0 or x.trips <> 0 or x.collection <> 0 or x.route_id is not null
   order by 14 desc nulls last, x.name;
end $$;

create or replace function incentive_statement(p_org uuid, p_month date, p_staff uuid default null)
returns table (staff_id uuid, staff_name text, role staff_role, scheme_id uuid, scheme_name text, basis text, rate numeric,
               sales numeric, returns numeric, net_sales numeric, collection numeric, boxes numeric, new_customers integer,
               base_value numeric, earned numeric)
language plpgsql stable as $$
#variable_conflict use_column
begin
  perform require_feature('insights');
  return query
  with m as (select date_trunc('month', p_month)::date as d1, (date_trunc('month', p_month) + interval '1 month')::date as d2),
  sch as (select s.* from incentive_schemes s, m
           where s.org_id = p_org and s.is_active and (s.valid_from is null or s.valid_from < m.d2) and (s.valid_till is null or s.valid_till >= m.d1)),
  st as (select s.id, s.full_name, s.role from staff s where s.org_id = p_org and s.is_active and (p_staff is null or s.id = p_staff)),
  -- named sal, not sales: an output column is called sales and plpgsql would see the variable
  sal as (
    select i.sales_exec_id as sid, sum(i.total) as sales,
           sum((select coalesce(sum(ii.boxes), 0) from invoice_items ii where ii.invoice_id = i.id)) as boxes
      from invoices i, m
     where i.org_id = p_org and i.status <> 'cancelled' and i.invoice_date >= m.d1 and i.invoice_date < m.d2 and i.sales_exec_id is not null
     group by 1),
  rets as (
    select i.sales_exec_id as sid, sum(r.total) as returns
      from sales_returns r join invoices i on i.id = r.invoice_id, m
     where r.org_id = p_org and r.return_date >= m.d1 and r.return_date < m.d2 and i.sales_exec_id is not null
     group by 1),
  coll as (
    select r.collected_by as sid, sum(r.total_amount) as collection
      from receipts r, m
     where r.org_id = p_org and r.receipt_date >= m.d1 and r.receipt_date < m.d2 and r.collected_by is not null
     group by 1),
  firsts as (select i.customer_id, min(i.invoice_date) as first_date from invoices i where i.org_id = p_org and i.status <> 'cancelled' group by 1),
  newc as (
    select i.sales_exec_id as sid, count(distinct i.customer_id) as n
      from invoices i join firsts f on f.customer_id = i.customer_id and f.first_date = i.invoice_date, m
     where i.org_id = p_org and i.status <> 'cancelled' and f.first_date >= m.d1 and f.first_date < m.d2 and i.sales_exec_id is not null
     group by 1),
  base as (
    select st.id, st.full_name, st.role,
           coalesce(sal.sales, 0) as sales, coalesce(rets.returns, 0) as returns,
           coalesce(sal.sales, 0) - coalesce(rets.returns, 0) as net_sales,
           coalesce(coll.collection, 0) as collection, coalesce(sal.boxes, 0) as boxes, coalesce(newc.n, 0)::int as new_customers
      from st
      left join sal on sal.sid = st.id
      left join rets on rets.sid = st.id
      left join coll on coll.sid = st.id
      left join newc on newc.sid = st.id)
  select b.id, b.full_name, b.role, s.id, s.name, s.basis, s.rate,
         b.sales, b.returns, b.net_sales, b.collection, b.boxes, b.new_customers,
         bv.v,
         round(case s.basis
                 when 'sales_pct' then bv.v * s.rate / 100
                 when 'collection_pct' then bv.v * s.rate / 100
                 when 'per_box' then bv.v * s.rate
                 when 'per_new_customer' then bv.v * s.rate
                 when 'slab' then bv.v * coalesce((select (e->>'pct')::numeric from jsonb_array_elements(s.slabs) e
                                                    where bv.v >= (e->>'from')::numeric and (e->>'to' is null or bv.v < (e->>'to')::numeric)
                                                    order by (e->>'from')::numeric desc limit 1), 0) / 100
                 else 0 end, 2)
    from base b
    join sch s on b.role = any(s.roles)
    cross join lateral (select case s.basis when 'collection_pct' then b.collection when 'per_box' then b.boxes
                                            when 'per_new_customer' then b.new_customers::numeric else b.net_sales end as v) bv
   order by b.full_name, s.name;
end $$;

-- Voice calls are part of the messaging module but only in the Full plan.
create or replace function queue_message(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare c customers%rowtype; t message_templates; v_vars jsonb; v_body text; v_id uuid; v_to text; v_purpose msg_purpose; v_media text; v_channel channel_kind;
begin
  select * into c from customers where id = (p->>'customer_id')::uuid;
  if not found then raise exception 'Customer not found'; end if;
  if not is_service_call() and c.org_id is distinct from my_org_id() then
    raise exception 'Customer belongs to another organisation';
  end if;
  v_purpose := (p->>'purpose')::msg_purpose;
  v_channel := nullif(p->>'channel', '')::channel_kind;
  v_to := normalize_mobile(coalesce(nullif(p->>'to_number', ''), c.mobile1));
  if v_to is null or not c.whatsapp_opt_in then return null; end if;

  if nullif(p->>'template_id', '') is not null then
    select * into t from message_templates where id = (p->>'template_id')::uuid and org_id = c.org_id;
  else
    t := pick_template(c.org_id, v_purpose, c.language, coalesce(v_channel, 'whatsapp'));
  end if;
  v_channel := coalesce(v_channel, t.channel, 'whatsapp');
  if v_channel = 'ivr_call' then perform require_feature('messaging'); end if;

  v_vars := jsonb_build_object(
              'org', (select name from orgs where id = c.org_id),
              'name', c.name, 'town', coalesce(c.town, ''),
              'outstanding', to_char(coalesce((select outstanding from v_customer_outstanding where customer_id = c.id), 0), 'FM9,99,99,990.00'),
              'date', to_char(current_date, 'DD-MM-YYYY'),
              'last_items', coalesce((select string_agg(it.name || ' ' || trim(to_char(ii.boxes, 'FM9990.##')), ', ' order by ii.id)
                                        from invoice_items ii join items it on it.id = ii.item_id
                                       where ii.invoice_id = (select i.id from invoices i where i.customer_id = c.id and i.status <> 'cancelled'
                                                               order by i.invoice_date desc, i.created_at desc limit 1)), ''))
            || coalesce(p->'vars', '{}'::jsonb);
  v_body := coalesce(nullif(p->>'body', ''), render_template(t.body, v_vars));
  if v_body is null or v_body = '' then
    raise exception 'No active % % for %', v_purpose, case when v_channel = 'ivr_call' then 'call script' else 'template' end, c.name;
  end if;
  v_media := nullif(p->>'media_url', '');

  insert into message_log (org_id, customer_id, template_id, channel, purpose, to_number, body, payload, status,
                           ref_table, ref_id, rule_id, broadcast_id)
  values (c.org_id, c.id, t.id, v_channel, v_purpose, v_to, v_body,
          jsonb_strip_nulls(jsonb_build_object('vars', v_vars, 'media_url', v_media, 'kind', nullif(p->>'kind', ''),
                                               'template_name', t.provider_template_name, 'language', coalesce(t.language, c.language))),
          'queued', nullif(p->>'ref_table', ''), nullif(p->>'ref_id', '')::uuid,
          nullif(p->>'rule_id', '')::uuid, nullif(p->>'broadcast_id', '')::uuid)
  returning id into v_id;
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 4. The plan reaches the app, and the vendor sets it.
-- ------------------------------------------------------------
create or replace function license_status(p_device_id text default null, p_app_version text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s record; o orgs%rowtype; n int; known boolean := false;
begin
  if v_org is null then raise exception 'Not a member of any organisation'; end if;
  select * into o from orgs where id = v_org;
  select * into s from license_state(v_org);
  if p_device_id is not null then
    update license_devices set last_seen = now(), app_version = coalesce(p_app_version, app_version)
     where org_id = v_org and device_id = p_device_id;
    known := found;
  end if;
  select count(*) into n from license_devices where org_id = v_org;
  return jsonb_build_object('status', s.status, 'valid_till', s.valid_till, 'days_left', s.days_left, 'read_only', s.read_only,
                            'grace_days', s.grace_days, 'trial_days', s.trial_days, 'licensed_to', o.licensed_to,
                            'has_key', o.license_key is not null, 'devices', n, 'max_devices', o.license_max_devices,
                            'this_device_known', known, 'checked_at', now(),
                            'plan', o.license_plan, 'plan_name', plan_label(o.license_plan),
                            'features', to_jsonb(plan_features(o.license_plan)),
                            'catalogue', (select jsonb_agg(to_jsonb(f)) from feature_catalogue() f));
end $$;

-- The plan is a new last argument, so the four-argument version has to go or every
-- existing four-argument call becomes ambiguous.
drop function if exists issue_license(uuid, date, text, integer);

create or replace function issue_license(p_org uuid, p_valid_till date, p_licensed_to text default null, p_max_devices integer default null, p_plan text default 'full') returns text
language plpgsql security definer set search_path = public as $$
declare v_key text; raw text;
begin
  if not is_service_call() then raise exception 'Licences are issued by the vendor only'; end if;
  if p_plan not in ('starter', 'growth', 'full') then raise exception 'Plan must be starter, growth or full'; end if;
  -- 20 hex characters of randomness. gen_random_uuid() is core Postgres and is
  -- always visible; gen_random_bytes() is pgcrypto, which Supabase installs into
  -- the extensions schema, and this function pins search_path to public — so the
  -- pgcrypto call resolved on a plain Postgres and failed on the real one.
  raw := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 20));
  v_key := 'JF-' || substr(raw, 1, 5) || '-' || substr(raw, 6, 5) || '-' || substr(raw, 11, 5) || '-' || substr(raw, 16, 5);
  update orgs set license_key = license_hash(v_key), license_valid_till = p_valid_till,
                  licensed_to = coalesce(p_licensed_to, licensed_to), license_max_devices = coalesce(p_max_devices, license_max_devices),
                  license_plan = p_plan
   where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
  return v_key;
end $$;

/** Move an organisation up (or back) a plan without reissuing the key. */
create or replace function set_license_plan(p_org uuid, p_plan text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_service_call() then raise exception 'Plans are set by the vendor only'; end if;
  if p_plan not in ('starter', 'growth', 'full') then raise exception 'Plan must be starter, growth or full'; end if;
  update orgs set license_plan = p_plan where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
  return plan_label(p_plan);
end $$;

revoke execute on function issue_license(uuid, date, text, integer, text) from public, anon, authenticated;
revoke execute on function set_license_plan(uuid, text) from public, anon, authenticated;


-- ════════════════════════════════════════════════════════════
-- from 22_attendance.sql
-- ════════════════════════════════════════════════════════════

-- ============================================================
-- JYOTHI FOODS ERP — 22: STAFF ATTENDANCE, AND PUNCHLY
--
-- The attendance table has existed since 01_schema.sql and was never
-- filled. This file fills it two ways: by hand, and from Punchly
-- (https://punchly.online/api/v1), the phone app the staff punch on.
--
-- Punchly gives punches — a check_in and a check_out event, each with
-- its own timestamp. This ERP wants one row per person per day. The
-- folding happens here, in upsert_punchly_attendance(), so the edge
-- function stays a thin fetch-and-hand-over.
--
-- Two rules that matter:
--   • a row a person edited by hand is never overwritten by a later
--     sync (attendance.source says who wrote it)
--   • punches arrive late — a phone out of signal delivers at 19:00
--     something that happened at 08:42 — so the sync always re-reads
--     yesterday as well as today, and upserts rather than inserts
-- ============================================================

-- ------------------------------------------------------------
-- 1. Who is who, and what a day looked like
-- ------------------------------------------------------------
alter table staff
  add column if not exists punchly_user_id text,
  add column if not exists punchly_staff_id text,
  add column if not exists designation text;
create unique index if not exists staff_punchly_idx on staff(org_id, punchly_user_id) where punchly_user_id is not null;

alter table attendance
  add column if not exists source text not null default 'manual' check (source in ('manual', 'punchly')),
  add column if not exists first_in_at timestamptz,
  add column if not exists last_out_at timestamptz,
  add column if not exists worked_hours numeric(6,2),
  add column if not exists punches integer not null default 0,
  add column if not exists branch_name text,
  add column if not exists shift_name text,
  add column if not exists needs_review boolean not null default false,
  add column if not exists notes text,
  add column if not exists updated_at timestamptz not null default now();
create index if not exists attendance_org_date_idx on attendance(org_id, work_date);

/** Staff wages are a payments matter, not a setup one — an accountant runs them. */
do $$
begin
  execute 'drop policy if exists org_read on attendance';
  execute 'drop policy if exists mod_insert on attendance';
  execute 'drop policy if exists mod_update on attendance';
  execute 'drop policy if exists mod_delete on attendance';
  execute 'create policy org_read on attendance for select using (org_id = my_org_id() and can_view(''payments''))';
  execute 'create policy mod_insert on attendance for insert with check (org_id = my_org_id() and can_edit(''payments''))';
  execute 'create policy mod_update on attendance for update using (org_id = my_org_id() and can_edit(''payments'')) with check (org_id = my_org_id() and can_edit(''payments''))';
  execute 'create policy mod_delete on attendance for delete using (org_id = my_org_id() and can_delete(''payments''))';
end $$;

/**
 * Punchly's key is a server-side secret, exactly like Hey Nikki's: this table gets no
 * policy for signed-in users at all, so the browser cannot read it however it asks. The
 * screen goes through get_punchly_settings(), which hands back the last four characters
 * and nothing else; only the edge function, on the service role, sees the whole key.
 */
create table if not exists punchly_settings (
  org_id          uuid primary key references orgs(id) on delete cascade,
  is_enabled      boolean not null default false,
  api_url         text not null default 'https://punchly.online/api/v1',
  api_key         text,
  /** A working day at or above this many hours is present; below it, half a day. */
  full_day_hours  numeric(5,2) not null default 8 check (full_day_hours > 0),
  /** Shorter than this and somebody should look at the row. */
  half_day_hours  numeric(5,2) not null default 4 check (half_day_hours > 0),
  /** Fill wage_amount from staff.daily_wage as the rows come in. */
  auto_wage       boolean not null default true,
  /**
   * Where each punch was made. The client wants it — a van salesman punching from the
   * route is the whole point of the geofence — so it is kept by default. It is still
   * personal data under the DPDP Act: switching this off drops the coordinates on the
   * way in, and clears the ones already stored on the next read of those days.
   */
  store_location  boolean not null default true,
  backfill_from   date,
  last_sync_at    timestamptz,
  last_sync_note  text,
  updated_at      timestamptz not null default now()
);
alter table punchly_settings
  /** Punchly asks for one wider pull a week, to catch what an admin corrected after the fact. */
  add column if not exists reconcile_days integer not null default 14 check (reconcile_days between 2 and 366),
  add column if not exists last_reconcile_at timestamptz;
-- create table if not exists leaves an older table's defaults alone, so say it again here
alter table punchly_settings alter column store_location set default true;
alter table punchly_settings enable row level security;
drop policy if exists org_scope on punchly_settings;

alter table attendance add column if not exists latitude numeric(9,6);
alter table attendance add column if not exists longitude numeric(9,6);

-- ------------------------------------------------------------
-- 2. Attendance is part of running the operation → Growth.
-- ------------------------------------------------------------
create or replace function plan_features(p_plan text) returns text[]
language sql immutable as $$
  select case p_plan
    when 'starter' then array['core']
    when 'growth'  then array['core', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents', 'attendance']
    else array['core', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents', 'attendance',
               'messaging', 'inventory', 'owner', 'insights', 'mobile', 'desktop']
  end;
$$;

create or replace function feature_catalogue()
returns table (feature text, label text, plan text, detail text)
language sql immutable as $$
  select * from (values
    ('core',       'Billing & collection', 'starter', 'Items, customers, invoices and prints, receipts, stock on hand, the day''s reports, setup and users'),
    ('purchases',  'Purchases',            'growth',  'Supplier bills, suppliers, purchase returns'),
    ('returns',    'Sales returns',        'growth',  'Fresh return, rate difference and damage return'),
    ('payments',   'Payments & accounts',  'growth',  'Payments, expenses, cash and bank books, cheques, journal, trial balance, P&L, balance sheet'),
    ('production', 'Production',           'growth',  'Recipes, batches, chief actuals, variance'),
    ('vehicles',   'Vans & trips',         'growth',  'Trips, van loading, loading sheet, settlement'),
    ('documents',  'Quotations & pricing', 'growth',  'Quotations, sale and purchase orders, delivery challans, price lists, discount schemes'),
    ('attendance', 'Attendance & wages',   'growth',  'The daily register, hours and wages per staff, and the Punchly phone-punch sync'),
    ('messaging',  'WhatsApp & calls',     'full',    'Templates, payment reminders, new-stock and catalog broadcasts, inbound orders, reminder and order-taking calls'),
    ('inventory',  'Batches & barcodes',   'full',    'Batch and expiry tracking, barcode labels, godown transfers, physical stock counts'),
    ('owner',      'Owner control',        'full',    'Print designer, backup and restore, audit trail'),
    ('insights',   'Profit & incentives',  'full',    'Route profitability and salesman incentive statements'),
    ('mobile',     'Driver''s phone',      'full',    'Van sales, on-the-spot receipts and delivery proof from a phone'),
    ('desktop',    'Desktop & offline',    'full',    'The installed Windows app, and working without a connection')
  ) as t(feature, label, plan, detail);
$$;

/**
 * Attendance rides on the Payments module, which opens at Growth, so a Starter client
 * cannot see the register at all — the rows keep sitting there, and Growth hands every
 * one of them back. The restrictive policy is what would stop the writes if attendance
 * were ever moved to a plan above the module it lives in; the module gate is doing the
 * work today. punchly_settings needs no policy: nobody signed in can reach it either way.
 */
do $$
begin
  execute 'drop policy if exists plan_insert on attendance';
  execute 'drop policy if exists plan_update on attendance';
  execute 'drop policy if exists plan_delete on attendance';
  execute 'create policy plan_insert on attendance as restrictive for insert with check (has_feature(''attendance''))';
  execute 'create policy plan_update on attendance as restrictive for update using (has_feature(''attendance''))';
  execute 'create policy plan_delete on attendance as restrictive for delete using (has_feature(''attendance''))';
end $$;

-- ------------------------------------------------------------
-- 3. Settings. The key is write-only to the screen, as Punchly asks:
--    it must never reach the browser bundle.
-- ------------------------------------------------------------
create or replace function get_punchly_settings() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s punchly_settings%rowtype;
begin
  if not can_view('payments') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  insert into punchly_settings (org_id) values (v_org) on conflict (org_id) do nothing;
  select * into s from punchly_settings where org_id = v_org;
  return jsonb_build_object(
    'is_enabled', s.is_enabled, 'api_url', s.api_url,
    'has_api_key', s.api_key is not null,
    'api_key_hint', case when s.api_key is null then null else '••••' || right(s.api_key, 4) end,
    'full_day_hours', s.full_day_hours, 'half_day_hours', s.half_day_hours,
    'auto_wage', s.auto_wage, 'store_location', s.store_location,
    'reconcile_days', s.reconcile_days, 'last_reconcile_at', s.last_reconcile_at,
    'backfill_from', s.backfill_from, 'last_sync_at', s.last_sync_at, 'last_sync_note', s.last_sync_note);
end $$;

create or replace function save_punchly_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not can_edit('payments') then raise exception 'Only a role with Payments edit rights can change these settings'; end if;
  perform require_feature('attendance');
  insert into punchly_settings (org_id) values (my_org_id()) on conflict (org_id) do nothing;
  update punchly_settings set
    api_url        = coalesce(nullif(p->>'api_url', ''), api_url),
    api_key        = case when nullif(p->>'api_key', '') is not null then p->>'api_key' else api_key end,
    is_enabled     = coalesce((p->>'is_enabled')::boolean, is_enabled),
    full_day_hours = coalesce(nullif(p->>'full_day_hours', '')::numeric, full_day_hours),
    half_day_hours = coalesce(nullif(p->>'half_day_hours', '')::numeric, half_day_hours),
    auto_wage      = coalesce((p->>'auto_wage')::boolean, auto_wage),
    store_location = coalesce((p->>'store_location')::boolean, store_location),
    reconcile_days = coalesce(nullif(p->>'reconcile_days', '')::integer, reconcile_days),
    backfill_from  = case when p ? 'backfill_from' then nullif(p->>'backfill_from', '')::date else backfill_from end,
    updated_at     = now()
  where org_id = my_org_id();
  return get_punchly_settings();
end $$;

/**
 * What the sync should ask Punchly for next. Three shapes, in order of precedence:
 *
 *   backfill  — history from backfill_from. The sync moves the marker along as each chunk
 *               lands, so a run that dies half way resumes where it stopped.
 *   reconcile — once every reconcile_days, one wider pull. Punchly's own advice: a day
 *               that has finished does not change on its own, but an admin can correct it
 *               afterwards, and nothing else would ever notice.
 *   ordinary  — yesterday and today. Yesterday because a phone out of signal at 08:42
 *               delivers its punch at 19:00, so a day is never finished on its first read.
 *
 * The dates are worked out in IST, because Punchly matches from/to against its own IST
 * attendance_date rather than an instant — these are working days, not timestamps.
 *
 * This hands back the raw key, so only the service role may call it.
 */
drop function if exists punchly_due(timestamptz);
create or replace function punchly_due(p_now timestamptz default now())
returns table (org_id uuid, api_url text, api_key text, from_date date, to_date date,
               is_backfill boolean, is_reconcile boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_today date := (p_now at time zone 'Asia/Kolkata')::date;
begin
  if not is_service_call() then raise exception 'Only the sync may read Punchly keys'; end if;
  return query
    with due as (
      select s.*, (s.backfill_from is not null) as backfill,
             (s.backfill_from is null
              and (s.last_reconcile_at is null or s.last_reconcile_at < p_now - make_interval(days => s.reconcile_days))) as reconcile
        from punchly_settings s
       where s.is_enabled and s.api_key is not null)
    select d.org_id, d.api_url, d.api_key,
           case when d.backfill then d.backfill_from
                when d.reconcile then v_today - d.reconcile_days
                else v_today - 1 end,
           v_today, d.backfill, d.reconcile
      from due d;
end $$;

/** A backfill chunk landed: move the marker past it, and clear it once history is caught up. */
create or replace function punchly_advance(p_org uuid, p_through date, p_now timestamptz default now()) returns date
language plpgsql security definer set search_path = public as $$
declare v_next date;
begin
  if not is_service_call() then raise exception 'Only the sync may move the backfill marker'; end if;
  v_next := case when p_through >= (p_now at time zone 'Asia/Kolkata')::date - 1 then null else p_through + 1 end;
  update punchly_settings set backfill_from = v_next, updated_at = now() where org_id = p_org;
  return v_next;
end $$;

-- ------------------------------------------------------------
-- 4. The roster. Auto-link on the Punchly user id, then on an exact
--    name, and hand back whatever is left for a human to match.
-- ------------------------------------------------------------
create or replace function upsert_punchly_staff(p_org uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb; v_id uuid; v_linked int := 0; v_named int := 0; v_unmatched jsonb := '[]'::jsonb;
begin
  if not is_service_call() and (p_org is distinct from my_org_id() or not has_role('owner', 'admin')) then
    raise exception 'Not allowed to sync this organisation';
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    select id into v_id from staff where org_id = p_org and punchly_user_id = r->>'user_id';
    if found then
      update staff set punchly_staff_id = r->>'staff_id', designation = coalesce(nullif(r->>'designation', ''), designation)
       where id = v_id;
      v_linked := v_linked + 1;
      continue;
    end if;
    -- not linked yet: one unambiguous name match is safe to take
    select s.id into v_id from staff s
     where s.org_id = p_org and s.punchly_user_id is null
       and lower(btrim(s.full_name)) = lower(btrim(r->>'full_name'))
     limit 2;
    if found and (select count(*) from staff s where s.org_id = p_org and s.punchly_user_id is null
                    and lower(btrim(s.full_name)) = lower(btrim(r->>'full_name'))) = 1 then
      update staff set punchly_user_id = r->>'user_id', punchly_staff_id = r->>'staff_id',
             designation = coalesce(nullif(r->>'designation', ''), designation)
       where id = v_id;
      v_named := v_named + 1;
    else
      v_unmatched := v_unmatched || jsonb_build_object('user_id', r->>'user_id', 'staff_id', r->>'staff_id', 'full_name', r->>'full_name');
    end if;
  end loop;
  return jsonb_build_object('linked', v_linked, 'matched_by_name', v_named,
                            'unmatched', v_unmatched, 'unmatched_count', jsonb_array_length(v_unmatched));
end $$;

/** Match a Punchly person to an ERP staff row by hand, from the screen. */
create or replace function link_punchly_staff(p_staff uuid, p_user_id text, p_staff_code text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  -- linking writes to the staff row, which is the owner's and the admin's to change
  if not has_role('owner', 'admin') then raise exception 'Only the owner or an admin can link staff to Punchly'; end if;
  perform require_feature('attendance');
  if nullif(p_user_id, '') is null then
    update staff set punchly_user_id = null, punchly_staff_id = null where id = p_staff and org_id = my_org_id();
  else
    update staff set punchly_user_id = p_user_id, punchly_staff_id = p_staff_code
     where id = p_staff and org_id = my_org_id();
  end if;
  if not found then raise exception 'Staff member not found'; end if;
end $$;

-- ------------------------------------------------------------
-- 5. Punches → one row a day. The whole fold lives here.
-- ------------------------------------------------------------
create or replace function upsert_punchly_attendance(p_org uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s punchly_settings%rowtype; rec record; v_written int := 0; v_kept int := 0; v_skipped int := 0;
        v_status attend_status; v_hours numeric; v_wage numeric; v_ot numeric;
begin
  if not is_service_call() and (p_org is distinct from my_org_id() or not can_edit('payments')) then
    raise exception 'Not allowed to sync this organisation';
  end if;
  select * into s from punchly_settings where org_id = p_org;
  if not found then raise exception 'Punchly is not set up for this organisation'; end if;

  for rec in
    with punch as (
      select x->>'staff_id' as code,
             nullif(x->>'punchly_user_id', '') as user_id,
             (x->>'attendance_date')::date as work_date,
             x->>'kind' as kind,
             (x->>'occurred_at')::timestamptz as at,
             nullif(x->>'branch_name', '') as branch_name,
             nullif(x->>'shift_name', '') as shift_name,
             nullif(x->>'latitude', '')::numeric as lat,
             nullif(x->>'longitude', '')::numeric as lon,
             coalesce(x->>'enforcement_status', 'ok') as enforcement
        from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x)
    select st.id as staff_id, st.daily_wage, p.work_date,
           min(p.at) filter (where p.kind = 'check_in') as first_in,
           max(p.at) filter (where p.kind = 'check_out') as last_out,
           count(*) as punches,
           (array_agg(p.branch_name) filter (where p.branch_name is not null))[1] as branch_name,
           (array_agg(p.shift_name) filter (where p.shift_name is not null))[1] as shift_name,
           (array_agg(p.lat) filter (where p.lat is not null))[1] as lat,
           (array_agg(p.lon) filter (where p.lon is not null))[1] as lon,
           bool_or(p.enforcement <> 'ok') as flagged
      from punch p
      join staff st on st.org_id = p_org
       and (st.punchly_user_id = p.user_id or (p.user_id is null and st.punchly_staff_id = p.code))
     group by st.id, st.daily_wage, p.work_date
  loop
    -- a row somebody typed by hand is the truth; the sync never argues with it
    if exists (select 1 from attendance a where a.staff_id = rec.staff_id and a.work_date = rec.work_date and a.source = 'manual') then
      v_kept := v_kept + 1;
      continue;
    end if;
    if rec.first_in is null and rec.last_out is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_hours := case when rec.first_in is not null and rec.last_out is not null and rec.last_out > rec.first_in
                    then round(extract(epoch from rec.last_out - rec.first_in) / 3600.0, 2) end;
    -- no check-out at all: they came, the phone did not record them leaving
    v_status := case when v_hours is null then 'present'
                     when v_hours >= s.full_day_hours then 'present'
                     else 'half_day' end;
    v_ot := case when v_hours is not null and v_hours > s.full_day_hours then round(v_hours - s.full_day_hours, 2) else 0 end;
    v_wage := case when not s.auto_wage then 0
                   when v_status = 'present' then coalesce(rec.daily_wage, 0)
                   else round(coalesce(rec.daily_wage, 0) / 2, 2) end;

    insert into attendance (org_id, staff_id, work_date, status, source,
                            in_time, out_time, first_in_at, last_out_at, worked_hours, ot_hours, wage_amount,
                            punches, branch_name, shift_name, latitude, longitude, needs_review, updated_at)
    values (p_org, rec.staff_id, rec.work_date, v_status, 'punchly',
            (rec.first_in at time zone 'Asia/Kolkata')::time, (rec.last_out at time zone 'Asia/Kolkata')::time,
            rec.first_in, rec.last_out, v_hours, v_ot, v_wage,
            rec.punches, rec.branch_name, rec.shift_name,
            case when s.store_location then rec.lat end, case when s.store_location then rec.lon end,
            rec.flagged or v_hours is null or (v_hours is not null and v_hours < s.half_day_hours), now())
    on conflict (staff_id, work_date) do update set
      status = excluded.status, source = 'punchly',
      in_time = excluded.in_time, out_time = excluded.out_time,
      first_in_at = excluded.first_in_at, last_out_at = excluded.last_out_at,
      worked_hours = excluded.worked_hours, ot_hours = excluded.ot_hours, wage_amount = excluded.wage_amount,
      punches = excluded.punches, branch_name = excluded.branch_name, shift_name = excluded.shift_name,
      latitude = excluded.latitude, longitude = excluded.longitude,
      needs_review = excluded.needs_review, updated_at = now();
    v_written := v_written + 1;
  end loop;

  update punchly_settings set last_sync_at = now(),
         last_sync_note = format('%s written, %s hand-typed rows kept, %s without a usable punch', v_written, v_kept, v_skipped)
   where org_id = p_org;
  return jsonb_build_object('written', v_written, 'kept_manual', v_kept, 'skipped', v_skipped);
end $$;

-- ------------------------------------------------------------
-- 6. What the screens read.
--
-- These are definer functions rather than views because only the owner
-- and admins may read the staff table, while an accountant is exactly
-- the person who runs the wage sheet. The plan, the module right and
-- the organisation are all checked here instead.
-- ------------------------------------------------------------
create or replace function attendance_register(p_from date, p_to date, p_staff uuid default null)
returns table (id uuid, staff_id uuid, full_name text, role staff_role, work_date date, status attend_status,
               source text, in_time time, out_time time, worked_hours numeric, ot_hours numeric,
               wage_amount numeric, punches integer, branch_name text, shift_name text,
               needs_review boolean, notes text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not can_view('payments') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  return query
    select a.id, a.staff_id, st.full_name, st.role, a.work_date, a.status, a.source,
           a.in_time, a.out_time, a.worked_hours, a.ot_hours, a.wage_amount, a.punches,
           a.branch_name, a.shift_name, a.needs_review, a.notes
      from attendance a
      join staff st on st.id = a.staff_id
     where a.org_id = my_org_id() and a.work_date between p_from and p_to
       and (p_staff is null or a.staff_id = p_staff)
     order by a.work_date desc, st.full_name;
end $$;

/** Days, hours and wages per person for a period — what a wage sheet is made of. */
create or replace function attendance_summary(p_from date, p_to date)
returns table (staff_id uuid, full_name text, role staff_role, is_mestry boolean, daily_wage numeric,
               present integer, half_days integer, absent integer, leave_days integer, holidays integer,
               worked_hours numeric, ot_hours numeric, wage numeric, needs_review integer)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not can_view('payments') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  return query
    select st.id, st.full_name, st.role, st.is_mestry, st.daily_wage,
           count(a.id) filter (where a.status = 'present')::int,
           count(a.id) filter (where a.status = 'half_day')::int,
           count(a.id) filter (where a.status = 'absent')::int,
           count(a.id) filter (where a.status = 'leave')::int,
           count(a.id) filter (where a.status = 'holiday')::int,
           round(coalesce(sum(a.worked_hours), 0), 2),
           round(coalesce(sum(a.ot_hours), 0), 2),
           round(coalesce(sum(a.wage_amount), 0), 2),
           count(a.id) filter (where a.needs_review)::int
      from staff st
      left join attendance a on a.staff_id = st.id and a.work_date between p_from and p_to
     where st.org_id = my_org_id() and st.is_active
     group by st.id, st.full_name, st.role, st.is_mestry, st.daily_wage
     order by st.full_name;
end $$;

/** The mapping screen: every staff member, and the Punchly person they are tied to. */
create or replace function punchly_roster()
returns table (id uuid, full_name text, role staff_role, is_mestry boolean, daily_wage numeric,
               designation text, punchly_user_id text, punchly_staff_id text, is_linked boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not has_role('owner', 'admin') then raise exception 'Only the owner or an admin can see the Punchly roster'; end if;
  perform require_feature('attendance');
  return query
    select st.id, st.full_name, st.role, st.is_mestry, st.daily_wage, st.designation,
           st.punchly_user_id, st.punchly_staff_id, (st.punchly_user_id is not null)
      from staff st where st.org_id = my_org_id() and st.is_active order by st.full_name;
end $$;

/**
 * The sync writing back what happened — including the runs that failed.
 *
 * The drop matters. This function gained p_reconciled after an earlier copy of this file
 * had already been applied somewhere, and `create or replace` cannot replace a function
 * whose argument list has changed — it adds a second one alongside. Both would then answer
 * to a three-argument call, and Postgres refuses to guess: "function punchly_note(uuid,
 * text, boolean) is not unique". The file applies cleanly and breaks at the first call.
 * Any later change to these arguments needs the same treatment.
 */
drop function if exists punchly_note(uuid, text, boolean);
create or replace function punchly_note(p_org uuid, p_note text, p_ok boolean default true,
                                        p_reconciled boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_service_call() then raise exception 'Only the sync may write here'; end if;
  update punchly_settings
     set last_sync_note = p_note,
         last_sync_at = case when p_ok then now() else last_sync_at end,
         last_reconcile_at = case when p_ok and p_reconciled then now() else last_reconcile_at end,
         updated_at = now()
   where org_id = p_org;
end $$;

/**
 * An employee asks to be forgotten (DPDP). Removing the rows is not enough on its own —
 * the next sync would fetch them straight back — so the Punchly link goes with them, and
 * the person has to be matched again deliberately if they ever return.
 */
create or replace function forget_staff_attendance(p_staff uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if my_role() <> 'owner' then raise exception 'Only the owner can erase somebody''s attendance'; end if;
  perform require_feature('attendance');
  update staff set punchly_user_id = null, punchly_staff_id = null
   where id = p_staff and org_id = my_org_id();
  if not found then raise exception 'Staff member not found'; end if;
  delete from attendance where staff_id = p_staff and org_id = my_org_id();
  get diagnostics n = row_count;
  return n;
end $$;

/** Type a day in by hand. Marks the row manual, so no later sync overwrites it. */
create or replace function save_attendance(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid; v_status attend_status; v_wage numeric; s punchly_settings%rowtype;
begin
  if not can_edit('payments') then raise exception 'Only a role with Payments edit rights can change attendance'; end if;
  perform require_feature('attendance');
  v_status := coalesce(nullif(p->>'status', ''), 'present')::attend_status;
  select * into s from punchly_settings where org_id = v_org;
  v_wage := case when p ? 'wage_amount' then nullif(p->>'wage_amount', '')::numeric
                 when coalesce(s.auto_wage, true) and v_status = 'present'
                   then (select daily_wage from staff where id = (p->>'staff_id')::uuid)
                 when coalesce(s.auto_wage, true) and v_status = 'half_day'
                   then round((select coalesce(daily_wage, 0) from staff where id = (p->>'staff_id')::uuid) / 2, 2)
                 else 0 end;
  insert into attendance (org_id, staff_id, work_date, status, source, in_time, out_time, ot_hours, wage_amount, notes, updated_at)
  values (v_org, (p->>'staff_id')::uuid, coalesce(nullif(p->>'work_date', '')::date, current_date), v_status, 'manual',
          nullif(p->>'in_time', '')::time, nullif(p->>'out_time', '')::time,
          coalesce(nullif(p->>'ot_hours', '')::numeric, 0), coalesce(v_wage, 0), nullif(p->>'notes', ''), now())
  on conflict (staff_id, work_date) do update set
    status = excluded.status, source = 'manual', in_time = excluded.in_time, out_time = excluded.out_time,
    ot_hours = excluded.ot_hours, wage_amount = excluded.wage_amount, notes = excluded.notes,
    needs_review = false, updated_at = now()
  returning id into v_id;
  return v_id;
end $$;

-- ------------------------------------------------------------
-- 7. The register travels with the rest of the org in a backup.
-- ------------------------------------------------------------
create or replace function snapshot_tables() returns text[]
language sql immutable as $$
  select array[
    'uoms', 'pack_types', 'item_categories', 'sections', 'items', 'item_price_overrides', 'price_lists', 'price_list_items:price_list_id:price_lists',
    'discount_schemes', 'item_barcodes', 'routes', 'customers', 'suppliers', 'stock_locations', 'vehicles', 'expense_heads', 'cash_bank_accounts', 'receipt_modes',
    'number_series', 'role_permissions', 'ledger_accounts', 'recipes', 'recipe_ingredients:recipe_id:recipes', 'production_batches', 'batch_ingredients:batch_id:production_batches',
    'item_batches', 'vehicle_trips', 'invoices', 'invoice_items:invoice_id:invoices', 'inbound_orders', 'quotations', 'quotation_items:quotation_id:quotations',
    'orders', 'order_items:order_id:orders', 'order_fulfilments', 'delivery_challans', 'challan_items:challan_id:delivery_challans',
    'purchases', 'purchase_items:purchase_id:purchases', 'purchase_returns', 'purchase_return_items:return_id:purchase_returns',
    'sales_returns', 'sales_return_items:return_id:sales_returns', 'receipts', 'receipt_lines:receipt_id:receipts', 'receipt_allocations:receipt_id:receipts',
    'payments', 'cheques', 'account_transfers', 'stock_transfers', 'stock_transfer_items:transfer_id:stock_transfers', 'stock_counts', 'stock_count_items:count_id:stock_counts',
    'stock_ledger', 'journal_entries', 'journal_lines:entry_id:journal_entries', 'account_transactions',
    'message_templates', 'reminder_rules', 'catalogs', 'broadcasts', 'new_stock_rules', 'message_log', 'transaction_message_settings', 'messaging_settings',
    'punchly_settings', 'print_templates', 'attendance', 'staff'
  ];
$$;


-- ════════════════════════════════════════════════════════════
-- from 23_extension_fix.sql
-- ════════════════════════════════════════════════════════════

-- ============================================================
-- JYOTHI FOODS ERP — 23: THE EXTENSION FIX, FOR DATABASES ALREADY BUILT
--
-- 13, 18 and 21 have been corrected in place, so a fresh install needs
-- nothing from this file. It exists for a database that is already running,
-- where re-running 13 is NOT the way to pick the fix up: 20_voice.sql widens
-- v_message_log, and `create or replace view` cannot narrow a view again —
-- "cannot drop columns from view". Migrations only ever go forward.
--
-- So this restates just the three functions that were wrong, and nothing else.
-- Safe to run on any database that has reached 21. Safe to run twice.
--
-- What was wrong: gen_random_bytes() belongs to pgcrypto, and Supabase keeps
-- pgcrypto in a schema called `extensions` rather than in public. Functions
-- that pin `search_path = public` therefore cannot see it, and issue_license()
-- failed with "function gen_random_bytes(integer) does not exist" — no licence
-- key could be issued at all. The random values now come from core Postgres
-- instead. similarity() is the same story from pg_trgm, but an extension
-- operator has no core equivalent, so that one names the schema explicitly.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The webhook secret's default, for a table that already exists
-- ------------------------------------------------------------
alter table messaging_settings alter column webhook_secret
  set default substr(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 1, 48);

-- ------------------------------------------------------------
-- 2. Rotating that secret by hand
-- ------------------------------------------------------------
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
-- 3. Matching a WhatsApp order's item names, which needs pg_trgm
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 4. Issuing a licence key — the one that was completely broken
-- ------------------------------------------------------------
create or replace function issue_license(p_org uuid, p_valid_till date, p_licensed_to text default null, p_max_devices integer default null, p_plan text default 'full') returns text
language plpgsql security definer set search_path = public as $$
declare v_key text; raw text;
begin
  if not is_service_call() then raise exception 'Licences are issued by the vendor only'; end if;
  if p_plan not in ('starter', 'growth', 'full') then raise exception 'Plan must be starter, growth or full'; end if;
  -- 20 hex characters of randomness. gen_random_uuid() is core Postgres and is
  -- always visible; gen_random_bytes() is pgcrypto, which Supabase installs into
  -- the extensions schema, and this function pins search_path to public — so the
  -- pgcrypto call resolved on a plain Postgres and failed on the real one.
  raw := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 20));
  v_key := 'JF-' || substr(raw, 1, 5) || '-' || substr(raw, 6, 5) || '-' || substr(raw, 11, 5) || '-' || substr(raw, 16, 5);
  update orgs set license_key = license_hash(v_key), license_valid_till = p_valid_till,
                  licensed_to = coalesce(p_licensed_to, licensed_to), license_max_devices = coalesce(p_max_devices, license_max_devices),
                  license_plan = p_plan
   where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
  return v_key;
end $$;

-- A quick proof it works, without changing anything:
--   select substr(replace(gen_random_uuid()::text, '-', ''), 1, 20);
-- If that returns 20 characters, issue_license() will now run.


-- ════════════════════════════════════════════════════════════
-- from 24_plan_trial.sql
-- ════════════════════════════════════════════════════════════

-- ============================================================
-- JYOTHI FOODS ERP — 24: A TASTE OF THE WHOLE THING
--
-- A client who has paid for Starter still gets a few days of everything, so
-- they can see what Growth and Full actually do before deciding. This is not
-- the licence trial in 18_licensing.sql and must not be confused with it:
--
--   licence trial   no key at all. Ends in READ-ONLY — no new invoices. It is
--                   the "you have not paid" state.
--   plan trial      this file. The licence is active and stays active; only
--                   the FEATURE SET steps down, on a date, to what was bought.
--
-- Using the licence trial for this would stop the client billing on day 11,
-- which is the opposite of the intent.
--
-- Nothing here schedules a job. my_plan() simply reads the date every time,
-- so the step-down happens on its own and cannot be forgotten.
-- ============================================================

alter table orgs
  /** Everything is unlocked until the end of this day. Null = no plan trial. */
  add column if not exists plan_full_until date;

/**
 * The plan in force right now.
 *
 * During a plan trial this is 'full' whatever was paid for; afterwards it is
 * license_plan again, and the client keeps every row they made in the meantime —
 * the locked screens hide, they do not delete. The service role is never capped.
 */
create or replace function my_plan() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select case when o.plan_full_until is not null and o.plan_full_until >= current_date
                 then 'full' else o.license_plan end
       from orgs o where o.id = my_org_id()),
    'starter');
$$;

/**
 * Start (or extend, or cancel) the plan trial. Vendor only, like issue_license:
 * a client who could call this could hand themselves Full for a decade.
 * p_days = 0 ends it now.
 */
create or replace function start_plan_trial(p_org uuid, p_days integer default 10) returns date
language plpgsql security definer set search_path = public as $$
declare v_until date;
begin
  if not is_service_call() then raise exception 'Plan trials are set by the vendor only'; end if;
  if p_days < 0 then raise exception 'Days cannot be negative'; end if;
  v_until := case when p_days = 0 then null else current_date + p_days - 1 end;
  update orgs set plan_full_until = v_until where id = p_org;
  if not found then raise exception 'Organisation not found'; end if;
  return v_until;
end $$;

revoke execute on function start_plan_trial(uuid, integer) from public, anon, authenticated;

/**
 * license_status() gains three fields so the screen can say what is happening
 * rather than silently showing Full to a Starter client:
 *
 *   plan            what is in force NOW — 'full' during the trial
 *   paid_plan       what the key actually bought, and what it drops back to
 *   plan_trial_days_left  null when there is no trial running
 */
create or replace function license_status(p_device_id text default null, p_app_version text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s record; o orgs%rowtype; n int; known boolean := false;
        v_plan text; v_left integer;
begin
  if v_org is null then raise exception 'Not a member of any organisation'; end if;
  select * into o from orgs where id = v_org;
  select * into s from license_state(v_org);
  if p_device_id is not null then
    update license_devices set last_seen = now(), app_version = coalesce(p_app_version, app_version)
     where org_id = v_org and device_id = p_device_id;
    known := found;
  end if;
  select count(*) into n from license_devices where org_id = v_org;

  v_plan := case when o.plan_full_until is not null and o.plan_full_until >= current_date
                 then 'full' else o.license_plan end;
  v_left := case when o.plan_full_until is not null and o.plan_full_until >= current_date
                 then (o.plan_full_until - current_date) + 1 end;

  return jsonb_build_object('status', s.status, 'valid_till', s.valid_till, 'days_left', s.days_left, 'read_only', s.read_only,
                            'grace_days', s.grace_days, 'trial_days', s.trial_days, 'licensed_to', o.licensed_to,
                            'has_key', o.license_key is not null, 'devices', n, 'max_devices', o.license_max_devices,
                            'this_device_known', known, 'checked_at', now(),
                            'plan', v_plan, 'plan_name', plan_label(v_plan),
                            'paid_plan', o.license_plan, 'paid_plan_name', plan_label(o.license_plan),
                            'plan_full_until', o.plan_full_until,
                            'plan_trial_days_left', v_left,
                            'features', to_jsonb(plan_features(v_plan)),
                            'catalogue', (select jsonb_agg(to_jsonb(f)) from feature_catalogue() f));
end $$;

-- ------------------------------------------------------------
-- How to use it, from the SQL Editor (vendor only):
--
--   -- issue what they paid for, then open everything for ten days
--   select issue_license((select id from orgs limit 1), '2027-09-30', 'Jyothi Foods, Guntur', 3, 'starter');
--   select start_plan_trial((select id from orgs limit 1), 10);
--
--   -- see where it stands
--   select name, license_plan as paid, plan_full_until from orgs;
--
--   -- end it early, or extend it
--   select start_plan_trial((select id from orgs limit 1), 0);
--   select start_plan_trial((select id from orgs limit 1), 20);
-- ------------------------------------------------------------


-- ════════════════════════════════════════════════════════════
-- from 25_daily_cap.sql
-- ════════════════════════════════════════════════════════════

-- ============================================================
-- JYOTHI FOODS ERP — 25: THE DAILY CAP COUNTED THE WRONG DAY
--
-- claim_queued_messages() compares message_log.sent_at, a timestamptz, against
-- the IST calendar date. Postgres casts that bare date to midnight UTC, which is
-- 05:30 IST — so the window the cap counted ran 05:30 to 05:30 rather than
-- midnight to midnight, and anything sent between midnight and 05:30 IST escaped
-- the cap entirely.
--
-- Quiet hours are 21:00 to 08:00 by default, so nothing normally sends in that
-- gap and it never showed. A test run happening to fall at 00:36 IST is what
-- finally caught it.
--
-- Fixed in 13 and 20 as well, for a fresh install. This file is for a database
-- already running: re-running 20 would drag queue_message back to its pre-21
-- version and undo the licence-plan guard, so the one function comes forward on
-- its own instead. Safe to run twice.
-- ============================================================

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
   -- The day the cap counts is an IST calendar day, so the boundary has to be IST
   -- midnight turned back into an instant. Comparing a timestamptz against a bare
   -- IST date casts that date to midnight UTC — 05:30 IST — which silently moves the
   -- window five and a half hours and lets anything sent after midnight escape the cap.
   where org_id = p_org
     and sent_at >= (((now() at time zone 'Asia/Kolkata')::date)::timestamp at time zone 'Asia/Kolkata');
  if v_sent_today >= s.daily_cap then return; end if;
  return query
    update message_log set attempts = attempts + 1, updated_at = now(), not_before = null
     where id in (select id from message_log
                   where org_id = p_org and status = 'queued' and attempts < 3
                     and (not_before is null or not_before <= now())
                     and (channel <> 'ivr_call' or s.voice_enabled)
                   order by created_at limit least(p_limit, s.daily_cap - v_sent_today))
    returning *;
end $$;


-- ════════════════════════════════════════════════════════════
-- from 27_attendance_in_starter.sql
-- ════════════════════════════════════════════════════════════

-- ============================================================
-- JYOTHI FOODS ERP — 27: ATTENDANCE BELONGS IN STARTER
--
-- A shop that only bills and collects still pays its staff, so the register
-- and the wage sheet go into the cheapest plan.
--
-- Moving the feature is one word. The reason this file is longer than one word
-- is that attendance was riding on the PAYMENTS module — the accountant's
-- module — and every module-gated policy asks can_view(module) BEFORE it asks
-- about the plan. Starter has no Payments, so the rows would stay hidden with
-- the feature switched on and nothing to explain why.
--
-- So attendance becomes a module of its own. That is the honest shape anyway:
-- who may see wages is a different question from who may see the cash book,
-- and until now they could not be answered separately.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Starter gets it. Everything above still includes it.
-- ------------------------------------------------------------
create or replace function plan_features(p_plan text) returns text[]
language sql immutable as $$
  select case p_plan
    when 'starter' then array['core', 'attendance']
    when 'growth'  then array['core', 'attendance', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents']
    else array['core', 'attendance', 'purchases', 'returns', 'payments', 'production', 'vehicles', 'documents',
               'messaging', 'inventory', 'owner', 'insights', 'mobile', 'desktop']
  end;
$$;

create or replace function feature_catalogue()
returns table (feature text, label text, plan text, detail text)
language sql immutable as $$
  select * from (values
    ('core',       'Billing & collection', 'starter', 'Items, customers, invoices and prints, receipts, stock on hand, the day''s reports, setup and users'),
    ('attendance', 'Attendance & wages',   'starter', 'The daily register, hours and wages per staff, and the Punchly phone-punch sync'),
    ('purchases',  'Purchases',            'growth',  'Supplier bills, suppliers, purchase returns'),
    ('returns',    'Sales returns',        'growth',  'Fresh return, rate difference and damage return'),
    ('payments',   'Payments & accounts',  'growth',  'Payments, expenses, cash and bank books, cheques, journal, trial balance, P&L, balance sheet'),
    ('production', 'Production',           'growth',  'Recipes, batches, chief actuals, variance'),
    ('vehicles',   'Vans & trips',         'growth',  'Trips, van loading, loading sheet, settlement'),
    ('documents',  'Quotations & pricing', 'growth',  'Quotations, sale and purchase orders, delivery challans, price lists, discount schemes'),
    ('messaging',  'WhatsApp & calls',     'full',    'Templates, payment reminders, new-stock and catalog broadcasts, inbound orders, reminder and order-taking calls'),
    ('inventory',  'Batches & barcodes',   'full',    'Batch and expiry tracking, barcode labels, godown transfers, physical stock counts'),
    ('owner',      'Owner control',        'full',    'Print designer, backup and restore, audit trail'),
    ('insights',   'Profit & incentives',  'full',    'Route profitability and salesman incentive statements'),
    ('mobile',     'Driver''s phone',      'full',    'Van sales, on-the-spot receipts and delivery proof from a phone'),
    ('desktop',    'Desktop & offline',    'full',    'The installed Windows app, and working without a connection')
  ) as t(feature, label, plan, detail);
$$;

/** Attendance is now its own module, so it is no longer 'core' by default. */
create or replace function module_feature(p_module text) returns text
language sql immutable as $$
  select case p_module
    when 'purchases'  then 'purchases'
    when 'returns'    then 'returns'
    when 'payments'   then 'payments'
    when 'production' then 'production'
    when 'vehicles'   then 'vehicles'
    when 'messaging'  then 'messaging'
    when 'attendance' then 'attendance'
    else 'core'
  end;
$$;

-- ------------------------------------------------------------
-- 2. Who may see wages, asked separately from who may see the books
-- ------------------------------------------------------------
create or replace function seed_role_permissions(p_org uuid)
returns void language sql as $$
  insert into role_permissions (org_id, role, module, can_view, can_edit, can_delete)
  select p_org, r.role, m.module,
         case when r.role = 'admin' then true
              when r.role = 'accountant'      then m.module in ('dashboard','customers','items','invoices','returns','receipts','payments','stock','reports','vehicles','attendance')
              when r.role = 'store_keeper'    then m.module in ('dashboard','items','purchases','stock','vehicles','reports')
              when r.role = 'production_head' then m.module in ('dashboard','items','stock','production','reports')
              when r.role = 'chief'           then m.module in ('dashboard','production')
              when r.role = 'driver'          then m.module in ('dashboard','invoices','receipts','vehicles')
              when r.role = 'sales_exec'      then m.module in ('dashboard','customers','items','invoices','returns','receipts','stock')
              else false end,
         case when r.role = 'admin' then true
              when r.role = 'accountant'      then m.module in ('customers','invoices','returns','receipts','payments','attendance')
              when r.role = 'store_keeper'    then m.module in ('items','purchases','stock','vehicles')
              when r.role = 'production_head' then m.module in ('production')
              when r.role = 'chief'           then m.module in ('production')
              when r.role = 'driver'          then m.module in ('invoices','receipts')
              when r.role = 'sales_exec'      then m.module in ('customers','invoices','receipts')
              else false end,
         case when r.role = 'admin' then m.module <> 'setup' else false end
  from unnest(enum_range(null::staff_role)) as r(role)
  cross join unnest(array['dashboard','items','customers','invoices','purchases','returns','receipts',
                          'payments','stock','production','vehicles','messaging','reports','setup','attendance']) as m(module)
  where r.role <> 'owner'
  on conflict (org_id, role, module) do nothing;
$$;

/**
 * Every organisation that already exists predates the module, so it has no rows
 * for it and every non-owner would be locked out. seed_role_permissions only
 * inserts what is missing, so running it again is exactly the backfill needed.
 */
do $$
declare o record;
begin
  for o in select id from orgs loop
    perform seed_role_permissions(o.id);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 3. The policies and the functions ask about attendance now
-- ------------------------------------------------------------
do $$
begin
  execute 'drop policy if exists org_read on attendance';
  execute 'drop policy if exists mod_insert on attendance';
  execute 'drop policy if exists mod_update on attendance';
  execute 'drop policy if exists mod_delete on attendance';
  execute 'create policy org_read on attendance for select using (org_id = my_org_id() and can_view(''attendance''))';
  execute 'create policy mod_insert on attendance for insert with check (org_id = my_org_id() and can_edit(''attendance''))';
  execute 'create policy mod_update on attendance for update using (org_id = my_org_id() and can_edit(''attendance'')) with check (org_id = my_org_id() and can_edit(''attendance''))';
  execute 'create policy mod_delete on attendance for delete using (org_id = my_org_id() and can_delete(''attendance''))';
end $$;

create or replace function get_punchly_settings() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); s punchly_settings%rowtype;
begin
  if not can_view('attendance') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  insert into punchly_settings (org_id) values (v_org) on conflict (org_id) do nothing;
  select * into s from punchly_settings where org_id = v_org;
  return jsonb_build_object(
    'is_enabled', s.is_enabled, 'api_url', s.api_url,
    'has_api_key', s.api_key is not null,
    'api_key_hint', case when s.api_key is null then null else '••••' || right(s.api_key, 4) end,
    'full_day_hours', s.full_day_hours, 'half_day_hours', s.half_day_hours,
    'auto_wage', s.auto_wage, 'store_location', s.store_location,
    'reconcile_days', s.reconcile_days, 'last_reconcile_at', s.last_reconcile_at,
    'backfill_from', s.backfill_from, 'last_sync_at', s.last_sync_at, 'last_sync_note', s.last_sync_note);
end $$;

create or replace function save_punchly_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not can_edit('attendance') then raise exception 'Only a role with Attendance edit rights can change these settings'; end if;
  perform require_feature('attendance');
  insert into punchly_settings (org_id) values (my_org_id()) on conflict (org_id) do nothing;
  update punchly_settings set
    api_url        = coalesce(nullif(p->>'api_url', ''), api_url),
    api_key        = case when nullif(p->>'api_key', '') is not null then p->>'api_key' else api_key end,
    is_enabled     = coalesce((p->>'is_enabled')::boolean, is_enabled),
    full_day_hours = coalesce(nullif(p->>'full_day_hours', '')::numeric, full_day_hours),
    half_day_hours = coalesce(nullif(p->>'half_day_hours', '')::numeric, half_day_hours),
    auto_wage      = coalesce((p->>'auto_wage')::boolean, auto_wage),
    store_location = coalesce((p->>'store_location')::boolean, store_location),
    reconcile_days = coalesce(nullif(p->>'reconcile_days', '')::integer, reconcile_days),
    backfill_from  = case when p ? 'backfill_from' then nullif(p->>'backfill_from', '')::date else backfill_from end,
    updated_at     = now()
  where org_id = my_org_id();
  return get_punchly_settings();
end $$;

create or replace function attendance_register(p_from date, p_to date, p_staff uuid default null)
returns table (id uuid, staff_id uuid, full_name text, role staff_role, work_date date, status attend_status,
               source text, in_time time, out_time time, worked_hours numeric, ot_hours numeric,
               wage_amount numeric, punches integer, branch_name text, shift_name text,
               needs_review boolean, notes text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not can_view('attendance') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  return query
    select a.id, a.staff_id, st.full_name, st.role, a.work_date, a.status, a.source,
           a.in_time, a.out_time, a.worked_hours, a.ot_hours, a.wage_amount, a.punches,
           a.branch_name, a.shift_name, a.needs_review, a.notes
      from attendance a
      join staff st on st.id = a.staff_id
     where a.org_id = my_org_id() and a.work_date between p_from and p_to
       and (p_staff is null or a.staff_id = p_staff)
     order by a.work_date desc, st.full_name;
end $$;

create or replace function attendance_summary(p_from date, p_to date)
returns table (staff_id uuid, full_name text, role staff_role, is_mestry boolean, daily_wage numeric,
               present integer, half_days integer, absent integer, leave_days integer, holidays integer,
               worked_hours numeric, ot_hours numeric, wage numeric, needs_review integer)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not can_view('attendance') then raise exception 'Attendance is not available to your role'; end if;
  perform require_feature('attendance');
  return query
    select st.id, st.full_name, st.role, st.is_mestry, st.daily_wage,
           count(a.id) filter (where a.status = 'present')::int,
           count(a.id) filter (where a.status = 'half_day')::int,
           count(a.id) filter (where a.status = 'absent')::int,
           count(a.id) filter (where a.status = 'leave')::int,
           count(a.id) filter (where a.status = 'holiday')::int,
           round(coalesce(sum(a.worked_hours), 0), 2),
           round(coalesce(sum(a.ot_hours), 0), 2),
           round(coalesce(sum(a.wage_amount), 0), 2),
           count(a.id) filter (where a.needs_review)::int
      from staff st
      left join attendance a on a.staff_id = st.id and a.work_date between p_from and p_to
     where st.org_id = my_org_id() and st.is_active
     group by st.id, st.full_name, st.role, st.is_mestry, st.daily_wage
     order by st.full_name;
end $$;

create or replace function save_attendance(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := my_org_id(); v_id uuid; v_status attend_status; v_wage numeric; s punchly_settings%rowtype;
begin
  if not can_edit('attendance') then raise exception 'Only a role with Attendance edit rights can change attendance'; end if;
  perform require_feature('attendance');
  v_status := coalesce(nullif(p->>'status', ''), 'present')::attend_status;
  select * into s from punchly_settings where org_id = v_org;
  v_wage := case when p ? 'wage_amount' then nullif(p->>'wage_amount', '')::numeric
                 when coalesce(s.auto_wage, true) and v_status = 'present'
                   then (select daily_wage from staff where id = (p->>'staff_id')::uuid)
                 when coalesce(s.auto_wage, true) and v_status = 'half_day'
                   then round((select coalesce(daily_wage, 0) from staff where id = (p->>'staff_id')::uuid) / 2, 2)
                 else 0 end;
  insert into attendance (org_id, staff_id, work_date, status, source, in_time, out_time, ot_hours, wage_amount, notes, updated_at)
  values (v_org, (p->>'staff_id')::uuid, coalesce(nullif(p->>'work_date', '')::date, current_date), v_status, 'manual',
          nullif(p->>'in_time', '')::time, nullif(p->>'out_time', '')::time,
          coalesce(nullif(p->>'ot_hours', '')::numeric, 0), coalesce(v_wage, 0), nullif(p->>'notes', ''), now())
  on conflict (staff_id, work_date) do update set
    status = excluded.status, source = 'manual', in_time = excluded.in_time, out_time = excluded.out_time,
    ot_hours = excluded.ot_hours, wage_amount = excluded.wage_amount, notes = excluded.notes,
    needs_review = false, updated_at = now()
  returning id into v_id;
  return v_id;
end $$;
