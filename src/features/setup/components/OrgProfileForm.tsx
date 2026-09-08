import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useRef } from 'react';
import { useForm } from 'react-hook-form';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { getOrg, updateOrg, uploadBranding } from '../api';
import { orNull, orgSchema, type OrgInput } from '../schema';

/**
 * Business profile + the printed trade terms. These numbers are the ONLY source
 * for breakage credit maths and the invoice footer (DOMAIN_RULES.md rule 12).
 * Logo and signature go to the public `branding` bucket and print on every sheet.
 */
export function OrgProfileForm({ compact }: { compact?: boolean }) {
  const perms = usePermissions();
  const queryClient = useQueryClient();
  const org = useQuery({ queryKey: ['setup', 'org'], queryFn: getOrg });

  const form = useForm<OrgInput>({
    resolver: zodResolver(orgSchema),
    defaultValues: {
      name: '',
      address: '',
      phone: '',
      fssai_no: '',
      breakage_recovery_pct: 50,
      interest_pct_pa: 24,
      credit_days: 15,
      jurisdiction: '',
      email: '',
      tagline: '',
      bank_details: '',
      app_url: '',
    },
  });

  useEffect(() => {
    if (org.data) {
      form.reset({
        name: org.data.name,
        address: org.data.address ?? '',
        phone: org.data.phone ?? '',
        fssai_no: org.data.fssai_no ?? '',
        breakage_recovery_pct: Number(org.data.breakage_recovery_pct),
        interest_pct_pa: Number(org.data.interest_pct_pa),
        credit_days: org.data.credit_days,
        jurisdiction: org.data.jurisdiction ?? '',
        email: org.data.email ?? '',
        tagline: org.data.tagline ?? '',
        bank_details: org.data.bank_details ?? '',
        app_url: org.data.app_url ?? '',
      });
    }
  }, [org.data, form]);

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: ['setup', 'org'] });
    await queryClient.invalidateQueries({ queryKey: ['me'] });
  };

  const save = useMutation({
    mutationFn: (v: OrgInput) => {
      if (!org.data) throw new Error('Organisation not loaded');
      return updateOrg(org.data.id, {
        name: v.name,
        address: orNull(v.address),
        phone: orNull(v.phone),
        fssai_no: orNull(v.fssai_no),
        breakage_recovery_pct: v.breakage_recovery_pct,
        interest_pct_pa: v.interest_pct_pa,
        credit_days: v.credit_days,
        jurisdiction: orNull(v.jurisdiction),
        email: orNull(v.email),
        tagline: orNull(v.tagline),
        bank_details: orNull(v.bank_details),
        app_url: orNull(v.app_url.replace(/\/+$/, '')),
      });
    },
    onSuccess: async () => {
      await invalidate();
      toast({ title: 'Business profile saved' });
    },
    onError: (err) => toastError(err, 'Could not save the business profile'),
  });

  const image = useMutation({
    mutationFn: async ({ kind, file }: { kind: 'logo' | 'signature'; file: File | null }) => {
      if (!org.data) throw new Error('Organisation not loaded');
      const url = file ? await uploadBranding(kind, file) : null;
      return updateOrg(org.data.id, kind === 'logo' ? { logo_url: url } : { signature_url: url });
    },
    onSuccess: async (_, v) => {
      await invalidate();
      toast({ title: v.file ? `${v.kind === 'logo' ? 'Logo' : 'Signature'} updated` : `${v.kind === 'logo' ? 'Logo' : 'Signature'} removed` });
    },
    onError: (err) => toastError(err, 'Could not update the image'),
  });

  if (org.isLoading) return <Spinner />;
  if (org.error)
    return (
      <p role="alert" className="text-sm text-destructive">
        Could not load the organisation: {org.error.message}
      </p>
    );

  const readOnly = !perms.isOwner;
  const e = form.formState.errors;

  return (
    <section className="space-y-3">
      <div>
        <h2 className={compact ? 'text-base font-semibold' : 'text-lg font-semibold'}>Business profile & trade terms</h2>
        <p className="max-w-2xl text-sm text-muted-foreground">
          Printed on every document under this trade name. The three trade terms drive the breakage credit and the
          numbered terms on the invoice footer — change them here, never in a template.
          {readOnly && ' Only the owner can change these.'}
        </p>
      </div>
      <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid max-w-3xl grid-cols-2 gap-3" noValidate>
        <fieldset disabled={readOnly} className="contents">
          <Field label="Trade name" htmlFor="org-name" error={e.name?.message} className="col-span-2">
            <Input id="org-name" {...form.register('name')} />
          </Field>
          <Field label="Tagline" htmlFor="org-tagline" error={e.tagline?.message} help="One line under the name on prints, e.g. Sweets & savouries since 1985." className="col-span-2">
            <Input id="org-tagline" {...form.register('tagline')} />
          </Field>
          <Field label="Address" htmlFor="org-address" error={e.address?.message} className="col-span-2">
            <Textarea id="org-address" rows={2} {...form.register('address')} />
          </Field>
          <Field label="Phone" htmlFor="org-phone" error={e.phone?.message}>
            <Input id="org-phone" inputMode="tel" {...form.register('phone')} />
          </Field>
          <Field label="Email" htmlFor="org-email" error={e.email?.message}>
            <Input id="org-email" inputMode="email" {...form.register('email')} />
          </Field>
          <Field label="FSSAI licence no." htmlFor="org-fssai" error={e.fssai_no?.message}>
            <Input id="org-fssai" {...form.register('fssai_no')} />
          </Field>
          <Field label="App web address" htmlFor="org-app" error={e.app_url?.message} help="Where this app is hosted; document links in WhatsApp messages start with it.">
            <Input id="org-app" inputMode="url" placeholder="https://erp.example.com" {...form.register('app_url')} />
          </Field>
          <Field label="Bank details" htmlFor="org-bank" error={e.bank_details?.message} help="Printed under the totals when the print template shows the bank block." className="col-span-2">
            <Textarea id="org-bank" rows={2} placeholder={'State Bank of India, Guntur\nA/c 1234567890 · IFSC SBIN0001234'} {...form.register('bank_details')} />
          </Field>

          <div className="col-span-2 mt-2 text-sm font-medium">Printed trade terms</div>
          <Field
            label="Breakage / damage recovery %"
            htmlFor="org-breakage"
            error={e.breakage_recovery_pct?.message}
            help="Credit given on a damage return, as a % of value."
          >
            <Input id="org-breakage" type="number" step="0.01" className="num" {...form.register('breakage_recovery_pct')} />
          </Field>
          <Field
            label="Interest % per annum"
            htmlFor="org-interest"
            error={e.interest_pct_pa?.message}
            help="Charged from bill date if unpaid within the credit days."
          >
            <Input id="org-interest" type="number" step="0.01" className="num" {...form.register('interest_pct_pa')} />
          </Field>
          <Field label="Credit days" htmlFor="org-credit" error={e.credit_days?.message}>
            <Input id="org-credit" type="number" className="num" {...form.register('credit_days')} />
          </Field>
          <Field label="Jurisdiction" htmlFor="org-jurisdiction" error={e.jurisdiction?.message} help='Printed as "Subject to … jurisdiction only".'>
            <Input id="org-jurisdiction" {...form.register('jurisdiction')} />
          </Field>
        </fieldset>
        {!readOnly && (
          <div className="col-span-2 flex justify-end pt-1">
            <Button type="submit" disabled={save.isPending || !form.formState.isDirty}>
              {save.isPending ? 'Saving…' : 'Save'}
            </Button>
          </div>
        )}
      </form>

      <div className="grid max-w-3xl grid-cols-1 gap-3 sm:grid-cols-2">
        <ImagePicker
          label="Logo"
          help="PNG or JPG, up to 2 MB. Printed top-left of every document."
          url={org.data?.logo_url ?? null}
          disabled={readOnly || image.isPending}
          onPick={(file) => image.mutate({ kind: 'logo', file })}
        />
        <ImagePicker
          label="Signature"
          help="A scan of the authorised signature, printed bottom-right."
          url={org.data?.signature_url ?? null}
          disabled={readOnly || image.isPending}
          onPick={(file) => image.mutate({ kind: 'signature', file })}
        />
      </div>
    </section>
  );
}

function ImagePicker({ label, help, url, disabled, onPick }: { label: string; help: string; url: string | null; disabled: boolean; onPick: (file: File | null) => void }) {
  const input = useRef<HTMLInputElement>(null);
  return (
    <div className="rounded-md border p-3">
      <div className="text-sm font-medium">{label}</div>
      <p className="text-xs text-muted-foreground">{help}</p>
      <div className="mt-2 flex items-center gap-3">
        <div className="flex h-16 w-32 items-center justify-center rounded border bg-white">
          {url ? <img src={url} alt={label} className="max-h-14 max-w-[7.5rem] object-contain" /> : <span className="text-xs text-muted-foreground">none</span>}
        </div>
        <input
          ref={input}
          type="file"
          accept="image/png,image/jpeg,image/webp,image/svg+xml"
          className="hidden"
          aria-label={`Choose ${label.toLowerCase()} file`}
          onChange={(ev) => {
            const f = ev.target.files?.[0] ?? null;
            if (f) onPick(f);
            ev.target.value = '';
          }}
        />
        <Button type="button" size="sm" variant="outline" disabled={disabled} onClick={() => input.current?.click()}>
          {url ? 'Replace' : 'Upload'}
        </Button>
        {url && (
          <Button type="button" size="sm" variant="ghost" className="text-destructive" disabled={disabled} onClick={() => onPick(null)}>
            Remove
          </Button>
        )}
      </div>
    </div>
  );
}
