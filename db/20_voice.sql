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
