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

-- Automatic backups: the function asks backups_due() which orgs have reached their run hour
-- (Setup → Backup: on/off, daily or weekly, time, copies to keep). Checked hourly at :05.
select cron.schedule('backup-org', '5 * * * *', $$select call_edge_function('backup-org')$$);

-- Punchly has no webhooks, so the punches are fetched rather than delivered. Twice an
-- hour is well inside the key's 1000-requests-an-hour limit (two calls per organisation
-- per run) and keeps the register close enough to live. The first run after a backfill
-- date is entered walks the whole history in yearly chunks, moving its marker as it goes;
-- every run after that reads today and yesterday, because a phone that was out of signal
-- delivers this morning's punch tonight.
select cron.schedule('punchly-sync', '12,42 * * * *', $$select call_edge_function('punchly-sync')$$);

-- To stop: select cron.unschedule('run-reminders'); select cron.unschedule('nikki-send'); select cron.unschedule('backup-org'); select cron.unschedule('punchly-sync');
