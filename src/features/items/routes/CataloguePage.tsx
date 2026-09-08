import { useQuery } from '@tanstack/react-query';
import { Printer } from 'lucide-react';
import { useState } from 'react';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { NativeSelect } from '@/components/ui/native-select';
import { useMe } from '@/features/auth/hooks';
import { sectionsApi } from '@/features/setup/api';
import { amount, int } from '@/lib/format';
import { catalogueItems } from '../api';

/**
 * The rate card: chosen products with their photo, pack and rate, laid out to be
 * printed or saved as a PDF and handed to a customer.
 *
 * Deliberately the item's own rate, not a customer's. A card priced for one shop
 * that reaches another is worse than no card, and a per-customer version would
 * have to read the price lists — a different job, and one nobody has asked for.
 */
export function CataloguePage() {
  const me = useMe();
  const [sectionId, setSectionId] = useState('');
  const [withImageOnly, setWithImageOnly] = useState(true);
  const [showRates, setShowRates] = useState(true);

  const sections = useQuery({ queryKey: ['setup', 'sections'], queryFn: sectionsApi.list });
  const rows = useQuery({
    queryKey: ['catalogue', sectionId, withImageOnly],
    queryFn: () => catalogueItems({ sectionId: sectionId || null, withImageOnly }),
  });

  const items = rows.data ?? [];
  const groups = items.reduce<Record<string, typeof items>>((acc, r) => {
    const key = r.section_name ?? 'Other';
    (acc[key] ??= []).push(r);
    return acc;
  }, {});

  return (
    <div className="space-y-4">
      <div className="no-print">
        <PageHeader
          title="Rate card"
          description="Products with their photo, pack and rate. Print it, or save as PDF and send it on WhatsApp."
          actions={
            <Button size="sm" variant="outline" onClick={() => window.print()} disabled={!items.length}>
              <Printer /> Print
            </Button>
          }
        />
      </div>

      <div className="no-print flex flex-wrap items-end gap-3">
        <Field label="Section" htmlFor="cat-section">
          <NativeSelect id="cat-section" className="h-8 w-56" value={sectionId} onChange={(e) => setSectionId(e.target.value)}>
            <option value="">Every section</option>
            {(sections.data ?? []).filter((s) => s.is_active).map((s) => (
              <option key={s.id} value={s.id}>{s.name}</option>
            ))}
          </NativeSelect>
        </Field>
        <label className="flex items-center gap-2 pb-1 text-sm">
          <Checkbox checked={withImageOnly} onChange={(e) => setWithImageOnly(e.target.checked)} />
          Only products with a photo
        </label>
        <label className="flex items-center gap-2 pb-1 text-sm">
          <Checkbox checked={showRates} onChange={(e) => setShowRates(e.target.checked)} />
          Show rates
        </label>
        <span className="pb-1 text-sm text-muted-foreground">{items.length} product{items.length === 1 ? '' : 's'}</span>
      </div>

      {rows.isLoading ? (
        <Spinner />
      ) : rows.error ? (
        <p role="alert" className="text-sm text-destructive">{rows.error.message}</p>
      ) : !items.length ? (
        <p className="no-print rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
          {withImageOnly
            ? 'No product in this section has a photo yet. Add one from the product screen, or untick the photo filter.'
            : 'No active products in this section.'}
        </p>
      ) : (
        <article className="rounded-md border p-6 print:border-0 print:p-0">
          <header className="mb-5 flex items-center gap-3 border-b pb-3">
            {me.data?.logo_url && <img src={me.data.logo_url} alt="" className="h-12 w-auto object-contain" />}
            <div>
              <h2 className="text-xl font-semibold">{me.data?.org_name ?? 'Rate card'}</h2>
              <p className="text-sm text-muted-foreground">
                {sectionId ? sections.data?.find((s) => s.id === sectionId)?.name : 'All products'}
                {' · '}
                {new Date().toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' })}
              </p>
            </div>
          </header>

          {Object.entries(groups).map(([section, list]) => (
            <section key={section} className="mb-6 break-inside-avoid">
              <h3 className="mb-2 text-sm font-semibold uppercase tracking-wide text-muted-foreground">{section}</h3>
              <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {list.map((r) => (
                  <div key={r.id ?? ''} className="flex gap-3 break-inside-avoid rounded-md border p-2">
                    {r.image_url ? (
                      <img src={r.image_url} alt="" className="h-20 w-20 shrink-0 rounded object-cover" />
                    ) : (
                      <div className="h-20 w-20 shrink-0 rounded bg-muted" />
                    )}
                    <div className="min-w-0">
                      <div className="truncate font-medium">{r.name}</div>
                      <div className="text-xs text-muted-foreground">
                        {r.pack ?? '—'}
                        {r.units_per_box ? ` · ${int(r.units_per_box)} per box` : ''}
                      </div>
                      {showRates && (
                        <div className="mt-1 text-sm">
                          <span className="font-semibold">{amount(r.unit_rate)}</span>
                          <span className="text-muted-foreground"> per {r.pack?.toLowerCase() ?? 'unit'}</span>
                          {r.box_rate ? <div className="text-xs text-muted-foreground">{amount(r.box_rate)} per box</div> : null}
                        </div>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </section>
          ))}

          <footer className="mt-6 border-t pt-3 text-xs text-muted-foreground">
            Rates are per {items[0]?.pack?.toLowerCase() ?? 'unit'} unless stated, and may change without notice.
          </footer>
        </article>
      )}
    </div>
  );
}
