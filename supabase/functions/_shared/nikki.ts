// Hey Nikki HTTP client, shared by the edge functions.
//
// The ERP → Nikki contract (docs/PROJECT_PLAN.md §5.1):
//   POST /v1/wa/send       one templated or free-text message to one number
//   POST /v1/wa/media      a document (catalog PDF) with a caption
//   POST /v1/wa/broadcast  many numbers, one body (unused: the ERP fans out itself so
//                          every recipient has its own message_log row)
//   POST /v1/voice/call    one outbound call: a Telugu/English script read by TTS, then
//                          either keys gathered (reminder: 1 / 2 / 3) or the bot takes an
//                          order in conversation (mode order_capture) and posts what it
//                          heard to the inbound webhook with our client_ref
// Every call carries the org's API key as a bearer token. Call events (ringing, answered,
// completed with dtmf / transcript / recording_url, no_answer, busy, failed) come back on
// the status webhook with the call_id. The voice shape is the ERP's best guess until Hey
// Nikki's voice docs arrive; only this file and the two webhooks need to change then.

export interface NikkiCall {
  to: string;
  script: string;
  language?: string | null;
  voice?: string | null;
  /** reminder → gather one key; order_capture → conversational order taking. */
  mode: 'reminder' | 'order_capture' | 'announce';
  client_ref: string;
}

export interface NikkiSend {
  to: string;
  body: string;
  template_name?: string | null;
  language?: string | null;
  media_url?: string | null;
  /** Our message_log id, echoed back on status callbacks. */
  client_ref: string;
}

export interface NikkiResult {
  ok: boolean;
  provider_msg_id?: string;
  error?: string;
}

export class NikkiClient {
  constructor(private readonly baseUrl: string, private readonly apiKey: string, private readonly sender?: string | null, private readonly caller?: string | null) {}

  async send(m: NikkiSend): Promise<NikkiResult> {
    const path = m.media_url ? '/v1/wa/media' : '/v1/wa/send';
    const payload = {
      from: this.sender ?? undefined,
      to: m.to.length === 10 ? `91${m.to}` : m.to,
      text: m.body,
      template: m.template_name ?? undefined,
      language: m.language ?? undefined,
      media_url: m.media_url ?? undefined,
      client_ref: m.client_ref,
    };
    return this.post(path, payload);
  }

  async call(c: NikkiCall): Promise<NikkiResult> {
    const payload = {
      from: this.caller ?? this.sender ?? undefined,
      to: c.to.length === 10 ? `91${c.to}` : c.to,
      script: c.script,
      language: c.language ?? 'te',
      voice: c.voice ?? undefined,
      mode: c.mode,
      gather: c.mode === 'reminder' ? { digits: 1, valid: ['1', '2', '3'], timeout_sec: 8 } : undefined,
      client_ref: c.client_ref,
    };
    return this.post('/v1/voice/call', payload);
  }

  private async post(path: string, payload: Record<string, unknown>): Promise<NikkiResult> {
    try {
      const res = await fetch(`${this.baseUrl.replace(/\/$/, '')}${path}`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const text = await res.text();
      let json: Record<string, unknown> = {};
      try {
        json = JSON.parse(text);
      } catch {
        // non-JSON error page
      }
      if (!res.ok) return { ok: false, error: String(json.error ?? json.message ?? `${res.status} ${text.slice(0, 200)}`) };
      const id = json.message_id ?? json.call_id ?? json.id ?? json.provider_msg_id;
      return { ok: true, provider_msg_id: id ? String(id) : undefined };
    } catch (e) {
      return { ok: false, error: e instanceof Error ? e.message : String(e) };
    }
  }
}
