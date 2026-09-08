// Drain an org's outbound queue through Hey Nikki. Used by nikki-send (on demand) and
// run-reminders (after queueing). The DB decides what may go out now —
// claim_queued_messages() applies the switch, quiet hours and the daily cap.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { NikkiClient } from './nikki.ts';

export interface DrainResult {
  org_id: string;
  claimed: number;
  sent: number;
  failed: number;
  skipped_reason?: string;
}

export async function drainOrg(admin: SupabaseClient, orgId: string, limit = 50): Promise<DrainResult> {
  const out: DrainResult = { org_id: orgId, claimed: 0, sent: 0, failed: 0 };

  const { data: settings, error: sErr } = await admin.from('messaging_settings').select('*').eq('org_id', orgId).maybeSingle();
  if (sErr) throw sErr;
  if (!settings || !settings.is_enabled || !settings.api_key) {
    out.skipped_reason = 'messaging is switched off or has no API key';
    return out;
  }

  const { data: rows, error } = await admin.rpc('claim_queued_messages', { p_org: orgId, p_limit: limit });
  if (error) throw error;
  const claimed = rows ?? [];
  out.claimed = claimed.length;
  if (!claimed.length) {
    out.skipped_reason = 'nothing to send now (empty, quiet hours, or daily cap)';
    return out;
  }

  const nikki = new NikkiClient(settings.api_url, settings.api_key, settings.sender_number, settings.caller_number);
  for (const m of claimed) {
    const payload = (m.payload ?? {}) as Record<string, unknown>;
    const r =
      m.channel === 'ivr_call'
        ? await nikki.call({
            to: m.to_number,
            script: m.body ?? '',
            language: (payload.language as string | undefined) ?? null,
            voice: settings.voice_name ?? null,
            mode: m.purpose === 'payment_reminder' ? 'reminder' : payload.kind === 'order_call' ? 'order_capture' : 'announce',
            client_ref: m.id,
          })
        : await nikki.send({
            to: m.to_number,
            body: m.body ?? '',
            template_name: (payload.template_name as string | undefined) ?? null,
            language: (payload.language as string | undefined) ?? null,
            media_url: (payload.media_url as string | undefined) ?? null,
            client_ref: m.id,
          });
    if (r.ok) {
      out.sent += 1;
      await admin.from('message_log').update({ status: 'sent', provider_msg_id: r.provider_msg_id ?? m.id, sent_at: new Date().toISOString(), error: null, updated_at: new Date().toISOString() }).eq('id', m.id);
    } else {
      out.failed += 1;
      // Three attempts, then it stays failed for the log screen to show.
      const final = (m.attempts ?? 1) >= 3;
      await admin.from('message_log').update({ status: final ? 'failed' : 'queued', error: r.error ?? 'send failed', updated_at: new Date().toISOString() }).eq('id', m.id);
    }
  }
  return out;
}
