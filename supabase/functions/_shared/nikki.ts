// Hey Nikki HTTP client, shared by the edge functions.
//
// The ERP → Nikki contract (docs/PROJECT_PLAN.md §5.1):
//   POST /v1/wa/send       one templated or free-text message to one number
//   POST /v1/wa/media      a document (catalog PDF) with a caption
//   POST /v1/wa/broadcast  many numbers, one body (unused: the ERP fans out itself so
//                          every recipient has its own message_log row)
// Every call carries the org's API key as a bearer token.

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
  constructor(private readonly baseUrl: string, private readonly apiKey: string, private readonly sender?: string | null) {}

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
      const id = json.message_id ?? json.id ?? json.provider_msg_id;
      return { ok: true, provider_msg_id: id ? String(id) : undefined };
    } catch (e) {
      return { ok: false, error: e instanceof Error ? e.message : String(e) };
    }
  }
}
