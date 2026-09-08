import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Play, Send } from 'lucide-react';
import { useState } from 'react';
import { MasterCrud, type MasterConfig, type Option } from '@/components/MasterCrud';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { routesApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { amount, dateTimeDMY, int } from '@/lib/format';
import { runRemindersNow, unknownPlaceholders } from '@/lib/nikki';
import { cn } from '@/lib/utils';
import { reminderRecipients, reminderRulesApi, runReminderRule, templatesApi, type ReminderRuleRow, type Template } from '../api';
import { CHANNELS, LANGUAGES, PURPOSES, reminderRuleSchema, templateSchema, type ReminderRuleInput, type TemplateInput } from '../schema';

function useRights() {
  const p = usePermissions();
  return { canEdit: p.canEdit('messaging'), canDelete: p.canDelete('messaging') };
}

const label = (opts: readonly Option[], v: string | null | undefined) => opts.find((o) => o.value === v)?.label ?? v ?? '';

// ------------------------------------------------------------------
// Templates — Telugu and English, one active per purpose and language
// ------------------------------------------------------------------
const STANDARD_TEMPLATES: TemplateInput[] = [
  { name: 'Reminder gentle (te)', purpose: 'payment_reminder', language: 'te', channel: 'whatsapp', provider_template_name: '', body: 'నమస్తే {{name}} గారు, {{org}} వద్ద మీ బకాయి ₹{{outstanding}}. దయచేసి త్వరగా చెల్లించండి. ధన్యవాదాలు.', is_active: true },
  { name: 'Reminder gentle (en)', purpose: 'payment_reminder', language: 'en', channel: 'whatsapp', provider_template_name: '', body: 'Namaste {{name}}, your outstanding at {{org}} is Rs {{outstanding}}. Kindly arrange payment. Thank you.', is_active: true },
  { name: 'Invoice copy (te)', purpose: 'invoice', language: 'te', channel: 'whatsapp', provider_template_name: '', body: '{{org}}: బిల్లు {{invoice_no}} ({{date}}) ₹{{amount}} పంపబడింది. వస్తువులు: {{items}}.', is_active: true },
  { name: 'Invoice copy (en)', purpose: 'invoice', language: 'en', channel: 'whatsapp', provider_template_name: '', body: '{{org}}: invoice {{invoice_no}} dated {{date}} for Rs {{amount}} has been dispatched. Items: {{items}}.', is_active: true },
  { name: 'Delivered (te)', purpose: 'delivery', language: 'te', channel: 'whatsapp', provider_template_name: '', body: '{{org}}: బిల్లు {{invoice_no}} ({{boxes}} బాక్సులు) డెలివరీ అయింది. ధన్యవాదాలు {{name}} గారు.', is_active: true },
  { name: 'Delivered (en)', purpose: 'delivery', language: 'en', channel: 'whatsapp', provider_template_name: '', body: '{{org}}: invoice {{invoice_no}} ({{boxes}} boxes) has been delivered. Thank you {{name}}.', is_active: true },
  { name: 'Order received (te)', purpose: 'order_ack', language: 'te', channel: 'whatsapp', provider_template_name: '', body: 'ధన్యవాదాలు {{name}} గారు! మీ ఆర్డర్ {{invoice_no}} ({{items}}) ₹{{amount}} సిద్ధమవుతోంది.', is_active: true },
  { name: 'Order received (en)', purpose: 'order_ack', language: 'en', channel: 'whatsapp', provider_template_name: '', body: 'Thanks {{name}}, your order {{invoice_no}} ({{items}}) for Rs {{amount}} is being packed.', is_active: true },
  { name: 'Receipt thanks (te)', purpose: 'custom', language: 'te', channel: 'whatsapp', provider_template_name: '', body: 'ధన్యవాదాలు {{name}} గారు! రసీదు {{receipt_no}} ₹{{amount}} అందింది. మిగిలిన బకాయి ₹{{outstanding}}.', is_active: true },
  { name: 'Receipt thanks (en)', purpose: 'custom', language: 'en', channel: 'whatsapp', provider_template_name: '', body: 'Thank you {{name}}! Receipt {{receipt_no}} for Rs {{amount}} received. Remaining outstanding Rs {{outstanding}}.', is_active: true },
  { name: 'New stock (te)', purpose: 'new_stock', language: 'te', channel: 'whatsapp', provider_template_name: '', body: '{{name}} గారు, {{item}} మళ్ళీ స్టాక్ లో ఉంది. ఈరోజే ఆర్డర్ చేయండి — {{org}}.', is_active: true },
  { name: 'New stock (en)', purpose: 'new_stock', language: 'en', channel: 'whatsapp', provider_template_name: '', body: '{{name}}, {{item}} is back in stock at {{org}}. Order today!', is_active: true },
  { name: 'Catalog (te)', purpose: 'catalog', language: 'te', channel: 'whatsapp', provider_template_name: '', body: '{{org}} కొత్త కేటలాగ్ {{catalog}} జతచేయబడింది ({{valid_to}} వరకు). ఆర్డర్ కోసం రిప్లై చేయండి.', is_active: true },
  { name: 'Catalog (en)', purpose: 'catalog', language: 'en', channel: 'whatsapp', provider_template_name: '', body: 'New catalog {{catalog}} from {{org}} attached (valid till {{valid_to}}). Reply to order.', is_active: true },
];

export function TemplatesPanel() {
  const rights = useRights();
  const config: MasterConfig<Template, TemplateInput> = {
    key: 'message_templates',
    title: 'Message templates',
    singular: 'Template',
    exportName: 'message-templates',
    description: (
      <>
        One template per purpose and language; the customer's language picks which one goes out. Placeholders:{' '}
        <code>{'{{name}} {{org}} {{outstanding}} {{oldest_days}} {{invoice_no}} {{amount}} {{items}} {{boxes}} {{receipt_no}} {{item}} {{catalog}} {{valid_to}} {{date}}'}</code>.
        A WhatsApp-approved template name goes in "Provider template" when Hey Nikki needs one.
      </>
    ),
    columns: [
      { key: 'name', label: 'Name' },
      { key: 'purpose', label: 'Purpose', render: (r) => label(PURPOSES, r.purpose) },
      { key: 'language', label: 'Lang', render: (r) => label(LANGUAGES, r.language) },
      { key: 'body', label: 'Body', render: (r) => <span className="line-clamp-2 max-w-md text-xs text-muted-foreground">{r.body}</span> },
      { key: 'is_active', label: 'Active' },
    ],
    fields: [
      { name: 'name', label: 'Name', autoFocus: true },
      { name: 'purpose', label: 'Purpose', type: 'select', options: PURPOSES, half: true },
      { name: 'language', label: 'Language', type: 'select', options: LANGUAGES, half: true },
      { name: 'channel', label: 'Channel', type: 'select', options: CHANNELS, half: true },
      { name: 'provider_template_name', label: 'Provider template (optional)', half: true, placeholder: 'jyothi_reminder_te' },
      { name: 'body', label: 'Body', type: 'textarea', help: 'Type in Telugu or English. Keep {{placeholders}} exactly as shown above.' },
      { name: 'is_active', label: 'Active', type: 'checkbox' },
    ],
    schema: templateSchema.refine((v) => unknownPlaceholders(v.body).length === 0, {
      path: ['body'],
      message: 'Unknown placeholder — check the spelling against the list above',
    }),
    defaults: { name: '', purpose: 'payment_reminder', language: 'te', channel: 'whatsapp', provider_template_name: '', body: '', is_active: true },
    toForm: (r) => ({
      name: r.name,
      purpose: r.purpose,
      language: r.language === 'en' ? 'en' : 'te',
      channel: r.channel === 'email' ? 'whatsapp' : r.channel,
      provider_template_name: r.provider_template_name ?? '',
      body: r.body,
      is_active: r.is_active,
    }),
    rowLabel: (r) => r.name,
    list: templatesApi.list,
    create: (v) => templatesApi.create({ ...v, provider_template_name: v.provider_template_name || null }),
    update: (id, v) => templatesApi.update(id, { ...v, provider_template_name: v.provider_template_name || null }),
    remove: templatesApi.remove,
    suggestions: { label: 'Add the standard set (Telugu + English)', rows: STANDARD_TEMPLATES, isPresent: (existing, s) => existing.some((e) => e.name === s.name) },
    ...rights,
  };
  return <MasterCrud config={config} />;
}

// ------------------------------------------------------------------
// Reminder rules — the escalation ladder
// ------------------------------------------------------------------
type RuleRow = ReminderRuleRow & { id: string };

export function RemindersPanel() {
  const rights = useRights();
  const templates = useQuery({ queryKey: ['setup', 'message_templates'], queryFn: templatesApi.list });
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list });
  const templateOptions: Option[] = [
    { value: '', label: '— by purpose and customer language —' },
    ...(templates.data ?? []).filter((t) => t.purpose === 'payment_reminder' && t.is_active).map((t) => ({ value: t.id, label: `${t.name} (${label(LANGUAGES, t.language)})` })),
  ];
  const routeOptions: Option[] = [{ value: '', label: 'All routes' }, ...(routes.data ?? []).map((r) => ({ value: r.id, label: r.name }))];

  const config: MasterConfig<RuleRow, ReminderRuleInput> = {
    key: 'reminder_rules',
    title: 'Payment reminder rules',
    singular: 'Rule',
    exportName: 'reminder-rules',
    description:
      'Rules are the ladder: a customer gets the rule with the highest "overdue days" they have crossed — gentle at 7, firm at 30, a call at 60. Overdue counts from the oldest unpaid bill plus your credit days (Setup → Business). Nobody is reminded twice within "repeat every". Runs daily at 10:00 through pg_cron; opted-out customers are always skipped.',
    columns: [
      { key: 'name', label: 'Name' },
      { key: 'overdue_days', label: 'Overdue ≥ days', align: 'right' },
      { key: 'min_outstanding', label: 'Min ₹', align: 'right', render: (r) => amount(r.min_outstanding) },
      { key: 'repeat_every_days', label: 'Repeat every', align: 'right', render: (r) => `${int(r.repeat_every_days)} d` },
      { key: 'template_name', label: 'Template', render: (r) => r.template_name ?? <span className="text-muted-foreground">by language</span> },
      { key: 'route_name', label: 'Route', render: (r) => r.route_name ?? 'All' },
      { key: 'sent_total', label: 'Sent', align: 'right', render: (r) => int(r.sent_total) },
      { key: 'last_run_at', label: 'Last run', render: (r) => (r.last_run_at ? dateTimeDMY(r.last_run_at) : '—') },
      { key: 'is_active', label: 'Active' },
    ],
    fields: [
      { name: 'name', label: 'Name', autoFocus: true, placeholder: 'Gentle / Firm / Final' },
      { name: 'overdue_days', label: 'Overdue at least (days)', type: 'number', half: true },
      { name: 'min_outstanding', label: 'Minimum outstanding (₹)', type: 'number', half: true, step: '0.01' },
      { name: 'repeat_every_days', label: 'Repeat every (days)', type: 'number', half: true },
      { name: 'channel', label: 'Channel', type: 'select', options: CHANNELS, half: true },
      { name: 'template_id', label: 'Template', type: 'select', options: templateOptions },
      { name: 'route_id', label: 'Only this route', type: 'select', options: routeOptions },
      { name: 'is_active', label: 'Active', type: 'checkbox' },
    ],
    schema: reminderRuleSchema,
    defaults: { name: '', template_id: '', min_outstanding: 1, overdue_days: 7, repeat_every_days: 7, channel: 'whatsapp', route_id: '', is_active: true },
    toForm: (r) => ({
      name: r.name ?? '',
      template_id: r.template_id ?? '',
      min_outstanding: Number(r.min_outstanding ?? 1),
      overdue_days: Number(r.overdue_days ?? 7),
      repeat_every_days: Number(r.repeat_every_days ?? 7),
      channel: r.channel === 'email' || !r.channel ? 'whatsapp' : r.channel,
      route_id: r.route_id ?? '',
      is_active: r.is_active ?? true,
    }),
    rowLabel: (r) => r.name ?? '',
    list: async () => (await reminderRulesApi.list()).map((r) => ({ ...r, id: r.id ?? '' })),
    create: (v) => reminderRulesApi.create({ ...v, template_id: v.template_id || null, route_id: v.route_id || null }),
    update: (id, v) => reminderRulesApi.update(id, { ...v, template_id: v.template_id || null, route_id: v.route_id || null }),
    remove: reminderRulesApi.remove,
    suggestions: {
      label: 'Add the gentle → firm → final ladder',
      rows: [
        { name: 'Gentle', template_id: '', min_outstanding: 1, overdue_days: 7, repeat_every_days: 7, channel: 'whatsapp', route_id: '', is_active: true },
        { name: 'Firm', template_id: '', min_outstanding: 1, overdue_days: 30, repeat_every_days: 7, channel: 'whatsapp', route_id: '', is_active: true },
        { name: 'Final', template_id: '', min_outstanding: 1, overdue_days: 60, repeat_every_days: 5, channel: 'whatsapp', route_id: '', is_active: true },
      ],
      isPresent: (existing, s) => existing.some((e) => e.name === s.name),
    },
    ...rights,
  };
  return (
    <div className="space-y-6">
      <MasterCrud config={config} />
      <RemindersPreview canEdit={rights.canEdit} />
    </div>
  );
}

function RemindersPreview({ canEdit }: { canEdit: boolean }) {
  const qc = useQueryClient();
  const rules = useQuery({ queryKey: ['setup', 'reminder_rules'], queryFn: reminderRulesApi.list });
  const [ruleId, setRuleId] = useState('');
  const recipients = useQuery({ queryKey: ['messaging', 'recipients', ruleId], queryFn: () => reminderRecipients(ruleId), enabled: Boolean(ruleId) });
  const run = useMutation({
    mutationFn: (dry: boolean) => runReminderRule(ruleId, dry),
    onSuccess: async (r) => {
      toast({ title: r.dry_run ? `Dry run: ${r.queued} of ${r.candidates} would be reminded` : `${r.queued} reminder${r.queued === 1 ? '' : 's'} queued`, description: r.skipped.length ? `${r.skipped.length} skipped — ${r.skipped.slice(0, 3).map((s) => `${s.name}: ${s.reason}`).join('; ')}` : undefined });
      await qc.invalidateQueries({ queryKey: ['messaging'] });
      await qc.invalidateQueries({ queryKey: ['setup', 'reminder_rules'] });
    },
    onError: (e) => toastError(e, 'Could not run the rule'),
  });
  const runAll = useMutation({
    mutationFn: runRemindersNow,
    onSuccess: async (r) => {
      const queued = r.runs.reduce((s, x) => s + x.queued, 0);
      const sent = r.sends.reduce((s, x) => s + x.sent, 0);
      toast({ title: `${queued} queued, ${sent} sent`, description: r.sends[0]?.skipped_reason });
      await qc.invalidateQueries({ queryKey: ['messaging'] });
    },
    onError: (e) => toastError(e, 'Could not run reminders'),
  });
  const rows = recipients.data ?? [];
  const due = rows.filter((r) => r.due).length;

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Who would a rule reach today?" htmlFor="rp-rule">
          <NativeSelect id="rp-rule" className="h-8 w-64" value={ruleId} onChange={(e) => setRuleId(e.target.value)}>
            <option value="">— pick a rule —</option>
            {(rules.data ?? []).map((r) => <option key={r.id ?? ''} value={r.id ?? ''}>{r.name}{r.is_active ? '' : ' (off)'}</option>)}
          </NativeSelect>
        </Field>
        {ruleId && rows.length > 0 && <Badge variant="secondary">{due} due of {rows.length}</Badge>}
        {canEdit && ruleId && (
          <>
            <Button size="sm" variant="outline" onClick={() => run.mutate(true)} disabled={run.isPending}>Dry run</Button>
            <Button size="sm" onClick={() => run.mutate(false)} disabled={run.isPending || !due}><Play /> Queue {due} now</Button>
          </>
        )}
        {canEdit && <Button size="sm" variant="outline" className="ml-auto" onClick={() => runAll.mutate()} disabled={runAll.isPending}><Send /> Run all rules & send</Button>}
      </div>
      {ruleId && (recipients.isLoading ? <Spinner /> : recipients.error ? (
        <p role="alert" className="text-sm text-destructive">{recipients.error.message}</p>
      ) : !rows.length ? (
        <p className="text-sm text-muted-foreground">Nobody matches this rule today (or a firmer rule takes them).</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Customer</TableHead><TableHead>Town</TableHead><TableHead>Mobile</TableHead><TableHead className="text-right">Outstanding</TableHead><TableHead className="text-right">Overdue</TableHead><TableHead>Last reminder</TableHead><TableHead>Today</TableHead></TableRow></TableHeader>
            <TableBody>
              {rows.map((r) => (
                <TableRow key={r.customer_id} className={cn(!r.due && 'text-muted-foreground')}>
                  <TableCell className="font-medium">{r.name}</TableCell><TableCell>{r.town}</TableCell><TableCell className="tabular-nums">{r.mobile1}</TableCell>
                  <TableCell className="num">{amount(r.outstanding)}</TableCell><TableCell className="num">{int(r.overdue_days)} d</TableCell>
                  <TableCell className="text-xs">{r.last_reminder_at ? dateTimeDMY(r.last_reminder_at) : 'never'}</TableCell>
                  <TableCell>{r.due ? <Badge>will send</Badge> : <span className="text-xs">{r.skip_reason}</span>}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      ))}
    </div>
  );
}
