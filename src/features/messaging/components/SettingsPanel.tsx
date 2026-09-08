import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Copy, RefreshCw } from 'lucide-react';
import { useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { webhookUrls } from '@/lib/nikki';
import { DOC_MESSAGE_TYPES, getMessagingSettings, listDocSettings, rotateWebhookSecret, saveDocSetting, saveMessagingSettings, templatesApi, type MessagingSettings } from '../api';
import { LANGUAGES, settingsSchema, type SettingsInput } from '../schema';

function toForm(s: MessagingSettings): SettingsInput {
  return { is_enabled: s.is_enabled, api_url: s.api_url, api_key: '', sender_number: s.sender_number ?? '', default_language: s.default_language === 'en' ? 'en' : 'te', quiet_from: s.quiet_from, quiet_to: s.quiet_to, daily_cap: s.daily_cap };
}

export function SettingsPanel() {
  const qc = useQueryClient();
  const perms = usePermissions();
  const canEdit = perms.canEdit('messaging');
  const settings = useQuery({ queryKey: ['messaging', 'settings'], queryFn: getMessagingSettings });
  const form = useForm<SettingsInput>({ resolver: zodResolver(settingsSchema), defaultValues: { is_enabled: false, api_url: 'https://heynikki.in', api_key: '', sender_number: '', default_language: 'te', quiet_from: '21:00', quiet_to: '08:00', daily_cap: 500 } });
  useEffect(() => {
    if (settings.data) form.reset(toForm(settings.data));
  }, [settings.data, form]);

  const save = useMutation({
    mutationFn: (v: SettingsInput) => saveMessagingSettings({ ...v, api_key: v.api_key || undefined }),
    onSuccess: async (s) => { toast({ title: 'Messaging settings saved' }); qc.setQueryData(['messaging', 'settings'], s); form.reset(toForm(s)); },
    onError: (e) => toastError(e, 'Could not save'),
  });
  const rotate = useMutation({
    mutationFn: rotateWebhookSecret,
    onSuccess: async () => { toast({ title: 'Webhook secret rotated', description: 'Update it in the Hey Nikki console; the old one stops working now.' }); await qc.invalidateQueries({ queryKey: ['messaging', 'settings'] }); },
    onError: (e) => toastError(e, 'Could not rotate'),
  });
  const copy = (text: string) => navigator.clipboard?.writeText(text).then(() => toast({ title: 'Copied' }));
  const urls = webhookUrls();
  const e = form.formState.errors;
  const s = settings.data;

  if (settings.isLoading) return <Spinner />;
  if (settings.error) return <p role="alert" className="text-sm text-destructive">{settings.error.message}</p>;

  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">Hey Nikki connection {s?.is_enabled ? <Badge>on</Badge> : <Badge variant="outline">off</Badge>}</CardTitle>
          <CardDescription>The API key is stored server-side only; the screen shows its last four characters. Leave the key blank to keep the current one.</CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3">
            <label className="col-span-2 flex items-center gap-2 text-sm"><Checkbox {...form.register('is_enabled')} disabled={!canEdit} /> Messaging switched on (nothing is sent while off; documents still queue nothing)</label>
            <Field label="API address" htmlFor="ms-url" className="col-span-2" error={e.api_url?.message}><Input id="ms-url" {...form.register('api_url')} disabled={!canEdit} /></Field>
            <Field label={s?.has_api_key ? `API key (current ${s.api_key_hint})` : 'API key'} htmlFor="ms-key" className="col-span-2" error={e.api_key?.message}>
              <Input id="ms-key" type="password" autoComplete="off" placeholder={s?.has_api_key ? 'unchanged' : 'paste the key from Hey Nikki'} {...form.register('api_key')} disabled={!canEdit} />
            </Field>
            <Field label="Sender WhatsApp number" htmlFor="ms-sender" error={e.sender_number?.message}><Input id="ms-sender" placeholder="91XXXXXXXXXX" {...form.register('sender_number')} disabled={!canEdit} /></Field>
            <Field label="Default language" htmlFor="ms-lang">
              <NativeSelect id="ms-lang" {...form.register('default_language')} disabled={!canEdit}>{LANGUAGES.map((l) => <option key={l.value} value={l.value}>{l.label}</option>)}</NativeSelect>
            </Field>
            <Field label="Quiet from" htmlFor="ms-qf" help="No messages go out between these times (IST)."><Input id="ms-qf" type="time" {...form.register('quiet_from')} disabled={!canEdit} /></Field>
            <Field label="Quiet to" htmlFor="ms-qt"><Input id="ms-qt" type="time" {...form.register('quiet_to')} disabled={!canEdit} /></Field>
            <Field label="Daily cap (messages)" htmlFor="ms-cap" error={e.daily_cap?.message}><Input id="ms-cap" type="number" className="num" {...form.register('daily_cap')} disabled={!canEdit} /></Field>
            {canEdit && <div className="col-span-2 flex justify-end"><Button type="submit" disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save settings'}</Button></div>}
          </form>
        </CardContent>
      </Card>

      <div className="space-y-4">
        <Card>
          <CardHeader>
            <CardTitle>Webhooks for the Hey Nikki console</CardTitle>
            <CardDescription>Hey Nikki posts inbound orders and delivery updates to these addresses with the secret in the <code>X-Nikki-Secret</code> header.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <Row label="Inbound orders" value={urls.inbound} onCopy={copy} />
            <Row label="Delivery status" value={urls.status} onCopy={copy} />
            <Row label="Secret" value={s?.webhook_secret ?? ''} onCopy={copy} mono />
            {canEdit && <Button size="sm" variant="outline" onClick={() => rotate.mutate()} disabled={rotate.isPending}><RefreshCw /> Rotate secret</Button>}
            <p className="text-xs text-muted-foreground">Deploy once: <code>supabase functions deploy nikki-send nikki-status nikki-inbound run-reminders</code>, then run <code>db/cron/schedule.sql</code> for the 10:00 reminders and the 5-minute sender.</p>
          </CardContent>
        </Card>
        <DocMessages canEdit={canEdit} />
      </div>
    </div>
  );
}

function Row({ label, value, onCopy, mono }: { label: string; value: string; onCopy: (v: string) => void; mono?: boolean }) {
  return (
    <div className="flex items-center gap-2">
      <span className="w-28 shrink-0 text-muted-foreground">{label}</span>
      <code className={mono ? 'truncate text-xs' : 'truncate'}>{value}</code>
      <Button size="sm" variant="ghost" aria-label={`Copy ${label}`} onClick={() => onCopy(value)}><Copy /></Button>
    </div>
  );
}

/** Which documents send a WhatsApp on their own, and with which template. */
function DocMessages({ canEdit }: { canEdit: boolean }) {
  const qc = useQueryClient();
  const templates = useQuery({ queryKey: ['setup', 'message_templates'], queryFn: templatesApi.list });
  const rows = useQuery({ queryKey: ['messaging', 'doc_settings'], queryFn: listDocSettings });
  const save = useMutation({
    mutationFn: ({ doc_type, ...v }: { doc_type: string; is_enabled: boolean; template_id: string | null; send_pdf: boolean }) => saveDocSetting(doc_type, v),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['messaging', 'doc_settings'] }),
    onError: (e) => toastError(e, 'Could not save'),
  });
  const current = (doc: string) => rows.data?.find((r) => r.doc_type === doc);
  return (
    <Card>
      <CardHeader>
        <CardTitle>Automatic document messages</CardTitle>
        <CardDescription>Each goes to the customer on the document, in their language, only while messaging is on. "Attach" adds the document itself (a link to its print page from the app's web address on the Business profile).</CardDescription>
      </CardHeader>
      <CardContent>
        {rows.isLoading ? <Spinner /> : (
          <Table>
            <TableHeader><TableRow><TableHead>Send</TableHead><TableHead>Document</TableHead><TableHead>Template</TableHead><TableHead>Attach</TableHead></TableRow></TableHeader>
            <TableBody>
              {DOC_MESSAGE_TYPES.map((d) => {
                const c = current(d.doc_type);
                const opts = (templates.data ?? []).filter((t) => t.is_active && t.purpose === d.purpose);
                const base = { doc_type: d.doc_type, is_enabled: c?.is_enabled ?? false, template_id: c?.template_id ?? null, send_pdf: c?.send_pdf ?? false };
                return (
                  <TableRow key={d.doc_type}>
                    <TableCell><Checkbox aria-label={`Send ${d.label}`} checked={base.is_enabled} disabled={!canEdit || save.isPending} onChange={(ev) => save.mutate({ ...base, is_enabled: ev.target.checked })} /></TableCell>
                    <TableCell><div className="font-medium">{d.label}</div><div className="text-xs text-muted-foreground">{d.when}</div></TableCell>
                    <TableCell>
                      <NativeSelect aria-label={`${d.label} template`} className="h-8" value={base.template_id ?? ''} disabled={!canEdit || save.isPending} onChange={(ev) => save.mutate({ ...base, template_id: ev.target.value || null })}>
                        <option value="">{d.purpose === 'custom' ? '— pick a template —' : '— by customer language —'}</option>
                        {opts.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                      </NativeSelect>
                    </TableCell>
                    <TableCell><Checkbox aria-label={`Attach ${d.label} document`} checked={base.send_pdf} disabled={!canEdit || save.isPending} onChange={(ev) => save.mutate({ ...base, send_pdf: ev.target.checked })} /></TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  );
}
