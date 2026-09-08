import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { Field } from '@/components/Field';
import { SalesDocPrint } from '@/components/print/SalesDocPrint';
import { defaultTerms } from '@/components/print/template';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { NativeSelect } from '@/components/ui/native-select';
import { Textarea } from '@/components/ui/textarea';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { cn } from '@/lib/utils';
import { getPrintTemplate, PAPERS, PRINT_BLOCKS, PRINT_DOC_TYPES, savePrintTemplate, type PrintDocType, type PrintTemplate } from '../api';

interface Draft {
  paper: string;
  show: Record<string, boolean>;
  terms: string;
  header: string;
  footer: string;
}

function toDraft(t: PrintTemplate | null): Draft {
  const sf = t?.show_fields && typeof t.show_fields === 'object' && !Array.isArray(t.show_fields) ? (t.show_fields as Record<string, unknown>) : {};
  const show: Record<string, boolean> = {};
  for (const b of PRINT_BLOCKS) show[b.key] = sf[b.key] === undefined ? true : Boolean(sf[b.key]);
  return { paper: t?.paper ?? 'A4', show, terms: (t?.terms ?? []).join('\n'), header: t?.header_html ?? '', footer: t?.footer_html ?? '' };
}

const SAMPLE_LINES = [
  { key: '1', code: '8', name: '5/- HT. MYSOOR PAK(12)', units_per_box: 32, boxes: 2, qty: 64, rate: 42, amount: 2688 },
  { key: '2', code: '21', name: '10/- KAJU BURFI (8)', units_per_box: 24, boxes: 1, qty: 24, rate: 85, amount: 2040 },
  { key: '3', code: '35', name: 'KARAPUSA 200g', units_per_box: 20, boxes: 3, qty: 60, rate: 28, amount: 1680 },
];

/**
 * Print designer: per document, the paper and every block or column, plus the wording
 * of the numbered terms. The preview on the right is the real sheet with sample lines.
 */
export function PrintDesigner({ compact }: { compact?: boolean }) {
  const perms = usePermissions();
  const me = useMe();
  const qc = useQueryClient();
  const [doc, setDoc] = useState<PrintDocType>('invoice');
  const template = useQuery({ queryKey: ['setup', 'print_templates', doc], queryFn: () => getPrintTemplate(doc) });
  const [draft, setDraft] = useState<Draft>(() => toDraft(null));
  const [dirty, setDirty] = useState(false);
  useEffect(() => {
    if (!template.isLoading) {
      setDraft(toDraft(template.data ?? null));
      setDirty(false);
    }
  }, [template.data, template.isLoading, doc]);

  const save = useMutation({
    mutationFn: () =>
      savePrintTemplate({
        doc_type: doc,
        paper: draft.paper,
        show_fields: draft.show,
        terms: draft.terms.split('\n').map((t) => t.trim()).filter(Boolean),
        header_html: draft.header.trim() || null,
        footer_html: draft.footer.trim() || null,
      }),
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['setup', 'print_templates'] });
      toast({ title: `${PRINT_DOC_TYPES.find((d) => d.key === doc)?.label ?? 'Template'} print saved` });
    },
    onError: (err) => toastError(err, 'Could not save the template'),
  });

  const canEdit = perms.canEdit('setup');
  const set = (patch: Partial<Draft>) => {
    setDraft((d) => ({ ...d, ...patch }));
    setDirty(true);
  };
  const money = doc !== 'challan';
  const previewTemplate = {
    paper: draft.paper,
    show_fields: draft.show,
    terms: draft.terms.split('\n').map((t) => t.trim()).filter(Boolean),
    header_html: draft.header || null,
    footer_html: draft.footer || null,
  };
  const scale = draft.paper === 'A4' ? 0.55 : draft.paper === 'A5' ? 0.75 : 1;

  return (
    <section className="space-y-3">
      <div>
        <h2 className={compact ? 'text-base font-semibold' : 'text-lg font-semibold'}>Print designer</h2>
        <p className="max-w-2xl text-sm text-muted-foreground">
          One layout per document. Tick what prints; the numbered terms can be reworded here — use{' '}
          <code>{'{breakage}'}</code>, <code>{'{interest}'}</code>, <code>{'{credit_days}'}</code> and <code>{'{jurisdiction}'}</code> so they
          always show the figures from the business profile. Leave the terms empty to print the standard three.
        </p>
      </div>
      <nav aria-label="Document" className="flex gap-1 border-b">
        {PRINT_DOC_TYPES.map((d) => (
          <button
            key={d.key}
            type="button"
            onClick={() => setDoc(d.key)}
            className={cn('-mb-px border-b-2 px-3 py-1.5 text-sm', doc === d.key ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}
          >
            {d.label}
          </button>
        ))}
      </nav>
      {template.isLoading ? (
        <Spinner />
      ) : (
        <div className="grid gap-4 lg:grid-cols-[22rem_1fr]">
          <fieldset disabled={!canEdit} className="space-y-3">
            <Field label="Paper" htmlFor="pd-paper">
              <NativeSelect id="pd-paper" value={draft.paper} onChange={(e) => set({ paper: e.target.value })}>
                {PAPERS.map((p) => (
                  <option key={p.key} value={p.key}>
                    {p.label}
                  </option>
                ))}
              </NativeSelect>
            </Field>
            {(['header', 'columns', 'footer'] as const).map((group) => (
              <div key={group}>
                <div className="mb-1 text-xs font-medium uppercase text-muted-foreground">{group}</div>
                <div className="grid grid-cols-2 gap-x-3 gap-y-1 text-sm">
                  {PRINT_BLOCKS.filter((b) => b.group === group && (money || !b.money)).map((b) => (
                    <label key={b.key} htmlFor={`pd-${b.key}`} className="flex items-center gap-2">
                      <Checkbox id={`pd-${b.key}`} checked={draft.show[b.key] ?? true} onChange={(e) => set({ show: { ...draft.show, [b.key]: e.target.checked } })} />
                      {b.label}
                    </label>
                  ))}
                </div>
              </div>
            ))}
            <Field label="Header line(s)" htmlFor="pd-header" help="Under the name and address, e.g. a GST-free note or a second phone.">
              <Textarea id="pd-header" rows={2} value={draft.header} onChange={(e) => set({ header: e.target.value })} />
            </Field>
            <Field label="Numbered terms, one per line" htmlFor="pd-terms" help={`Standard: ${defaultTerms(me.data).join(' / ')}`}>
              <Textarea id="pd-terms" rows={4} value={draft.terms} placeholder={defaultTerms(me.data).join('\n')} onChange={(e) => set({ terms: e.target.value })} />
            </Field>
            <Field label="Footer line(s)" htmlFor="pd-footer">
              <Textarea id="pd-footer" rows={2} value={draft.footer} onChange={(e) => set({ footer: e.target.value })} />
            </Field>
            {canEdit && (
              <div className="flex justify-end gap-2">
                <Button type="button" variant="outline" onClick={() => { setDraft(toDraft(template.data ?? null)); setDirty(false); }} disabled={!dirty}>
                  Undo changes
                </Button>
                <Button type="button" onClick={() => save.mutate()} disabled={save.isPending || !dirty}>
                  {save.isPending ? 'Saving…' : 'Save layout'}
                </Button>
              </div>
            )}
          </fieldset>
          <div className="overflow-auto rounded-md border bg-neutral-200 p-3" aria-label="Preview">
            <div style={{ transform: `scale(${scale})`, transformOrigin: 'top left', width: `${100 / scale}%` }}>
              <div className="inline-block shadow">
                <SalesDocPrint
                  preview
                  title={doc === 'invoice' ? 'INVOICE' : doc === 'quotation' ? 'QUOTATION' : 'DELIVERY CHALLAN'}
                  org={me.data}
                  template={previewTemplate}
                  party={{ name: 'P. SRINIVAS (MCL)', town: 'MACHARLA', phones: '9849686746' }}
                  meta={[
                    { label: 'Date', value: '08-09-2026', bold: true },
                    { label: 'No.', value: 'JF-0001', bold: true },
                    { label: 'Transport Name', value: 'KAVERI', transport: true },
                    { label: 'L.R No.', value: '4521', transport: true },
                  ]}
                  lines={SAMPLE_LINES}
                  totals={money ? { discount: 0, freight: 120, round_off: 0.5, total: 6528 } : null}
                />
              </div>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}
