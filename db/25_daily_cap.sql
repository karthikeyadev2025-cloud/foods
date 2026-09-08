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
