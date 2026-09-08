import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { Field } from '@/components/Field';
import { MasterCrud, type MasterConfig } from '@/components/MasterCrud';
import { Button } from '@/components/ui/button';
import { NativeSelect } from '@/components/ui/native-select';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { assignSalesExec, INCENTIVE_BASES, incentiveSchemesApi, listStaff, parseSlabs, routesApi, slabsText, type IncentiveScheme } from '../api';
import { incentiveSchemeSchema, type IncentiveSchemeInput } from '../schema';

const basisLabel = (b: string) => INCENTIVE_BASES.find((x) => x.value === b)?.label ?? b;

/**
 * Incentive schemes (what a salesman earns on what) and the route → salesman
 * assignment that decides whose bills they are. The monthly statement is under
 * Reports → Incentives.
 */
export function IncentivesPanel({ compact }: { compact?: boolean }) {
  const perms = usePermissions();
  const config: MasterConfig<IncentiveScheme, IncentiveSchemeInput> = {
    key: 'incentive_schemes',
    title: 'Incentive schemes',
    singular: 'Scheme',
    exportName: 'incentive-schemes',
    description:
      'Each active scheme pays every sales executive / driver it applies to, every month, on the base it names. A slab scheme reads the monthly net sales and applies the percentage of the slab reached to the whole month. The client confirms the actual scheme before it goes live.',
    columns: [
      { key: 'name', label: 'Scheme' },
      { key: 'basis', label: 'Basis', render: (r) => basisLabel(r.basis) },
      { key: 'rate', label: 'Rate', align: 'right', render: (r) => (r.basis === 'slab' ? slabsText(r.slabs).replace(/\n/g, ' · ') : String(Number(r.rate))) },
      { key: 'roles', label: 'For', render: (r) => (r.roles ?? []).map((x) => (x === 'sales_exec' ? 'Sales exec' : x === 'driver' ? 'Driver' : x)).join(', ') },
      { key: 'valid_from', label: 'From', render: (r) => r.valid_from ?? '—' },
      { key: 'valid_till', label: 'Till', render: (r) => r.valid_till ?? '—' },
      { key: 'is_active', label: 'Active' },
    ],
    fields: [
      { name: 'name', label: 'Scheme name', autoFocus: true, placeholder: '1% of net sales' },
      { name: 'basis', label: 'Basis', type: 'select', options: INCENTIVE_BASES },
      { name: 'rate', label: 'Rate (% or ₹, not for slab)', type: 'number', step: '0.01', half: true },
      { name: 'slabs_text', label: 'Slabs (slab basis only)', type: 'textarea', placeholder: '0-100000:0.5\n100000-300000:1\n300000+:2', help: 'One per line: from-to:percent, last line from+:percent.' },
      { name: 'for_sales_exec', label: 'Applies to sales executives', type: 'checkbox', half: true },
      { name: 'for_driver', label: 'Applies to drivers', type: 'checkbox', half: true },
      { name: 'valid_from', label: 'Valid from (YYYY-MM-DD, blank = always)', half: true },
      { name: 'valid_till', label: 'Valid till (YYYY-MM-DD, blank = open)', half: true },
      { name: 'is_active', label: 'Active', type: 'checkbox' },
    ],
    schema: incentiveSchemeSchema,
    defaults: { name: '', basis: 'sales_pct', rate: 1, slabs_text: '', for_sales_exec: true, for_driver: false, valid_from: '', valid_till: '', is_active: true },
    toForm: (r) => ({
      name: r.name,
      basis: r.basis as IncentiveSchemeInput['basis'],
      rate: Number(r.rate),
      slabs_text: slabsText(r.slabs),
      for_sales_exec: (r.roles ?? []).includes('sales_exec'),
      for_driver: (r.roles ?? []).includes('driver'),
      valid_from: r.valid_from ?? '',
      valid_till: r.valid_till ?? '',
      is_active: r.is_active,
    }),
    rowLabel: (r) => r.name,
    list: incentiveSchemesApi.list,
    create: (v) => incentiveSchemesApi.create(toRow(v)),
    update: (id, v) => incentiveSchemesApi.update(id, toRow(v)),
    remove: incentiveSchemesApi.remove,
    canEdit: perms.canEdit('setup'),
    canDelete: perms.canDelete('setup'),
  };
  return (
    <div className="space-y-6">
      <MasterCrud config={config} compact={compact} />
      <AssignRoute canEdit={perms.canEdit('customers')} />
    </div>
  );
}

function toRow(v: IncentiveSchemeInput) {
  const roles: ('sales_exec' | 'driver')[] = [];
  if (v.for_sales_exec) roles.push('sales_exec');
  if (v.for_driver) roles.push('driver');
  if (!roles.length) throw new Error('Tick at least one role the scheme applies to');
  const slabs = v.basis === 'slab' ? parseSlabs(v.slabs_text) : [];
  if (v.basis === 'slab' && !slabs.length) throw new Error('A slab scheme needs at least one slab line');
  return {
    name: v.name,
    basis: v.basis,
    rate: v.basis === 'slab' ? 0 : v.rate,
    slabs: slabs as unknown as IncentiveScheme['slabs'],
    roles,
    valid_from: v.valid_from || null,
    valid_till: v.valid_till || null,
    is_active: v.is_active,
  };
}

function AssignRoute({ canEdit }: { canEdit: boolean }) {
  const qc = useQueryClient();
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list });
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const [routeId, setRouteId] = useState('');
  const [staffId, setStaffId] = useState('');
  const assign = useMutation({
    mutationFn: () => {
      if (!routeId) throw new Error('Pick a route');
      return assignSalesExec(staffId || null, routeId);
    },
    onSuccess: async (n) => {
      await qc.invalidateQueries({ queryKey: ['customers'] });
      toast({ title: `${n} customer${n === 1 ? '' : 's'} ${staffId ? 'assigned' : 'cleared'}` });
    },
    onError: (err) => toastError(err, 'Could not assign'),
  });
  return (
    <section className="space-y-2">
      <div>
        <h3 className="text-base font-semibold">Assign a route to a salesman</h3>
        <p className="max-w-2xl text-sm text-muted-foreground">
          Sets the salesman on every customer of the route (one customer at a time is on the customer form). A bill counts for the
          customer's salesman; without one, for the sales executive or driver who made it.
        </p>
      </div>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Route" htmlFor="as-route">
          <NativeSelect id="as-route" className="h-8 w-48" value={routeId} onChange={(e) => setRouteId(e.target.value)} disabled={!canEdit}>
            <option value="">— pick —</option>
            {(routes.data ?? []).filter((r) => r.is_active).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
          </NativeSelect>
        </Field>
        <Field label="Salesman" htmlFor="as-staff">
          <NativeSelect id="as-staff" className="h-8 w-48" value={staffId} onChange={(e) => setStaffId(e.target.value)} disabled={!canEdit}>
            <option value="">— nobody (clear) —</option>
            {(staff.data ?? []).filter((s) => s.is_active && (s.role === 'sales_exec' || s.role === 'driver')).map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </NativeSelect>
        </Field>
        <Button size="sm" onClick={() => assign.mutate()} disabled={!canEdit || !routeId || assign.isPending}>{assign.isPending ? 'Assigning…' : 'Assign'}</Button>
      </div>
    </section>
  );
}
