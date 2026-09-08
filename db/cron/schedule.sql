-- ============================================================
-- pg_cron schedule for messaging. Run once in the Supabase SQL
-- Editor AFTER deploying the edge functions. Not part of apply.sh
-- (pg_cron and pg_net exist only on Supabase).
--
-- Replace <project-ref> and <service-role-key>. The key is stored
-- in Vault so it never sits in the cron table in clear:
--   select vault.create_secret('<service-role-key>', 'service_role_key');
-- ============================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

create or replace function call_edge_function(p_name text, p_body jsonb default '{}'::jsonb) returns bigint
language plpgsql security definer as $$
declare v_key text; v_url text := 'https://<project-ref>.supabase.co/functions/v1/' || p_name;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key';
  return net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := p_body,
    timeout_milliseconds := 60000);
end $$;

-- Payment reminders at 10:00 IST (04:30 UTC) every day.
select cron.schedule('run-reminders', '30 4 * * *', $$select call_edge_function('run-reminders')$$);

-- Drain the outbound queue every 5 minutes (quiet hours and the daily cap are applied in claim_queued_messages()).
select cron.schedule('nikki-send', '*/5 * * * *', $$select call_edge_function('nikki-send')$$);

-- To stop: select cron.unschedule('run-reminders'); select cron.unschedule('nikki-send');
