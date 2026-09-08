import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useForm } from 'react-hook-form';
import { Field } from '@/components/Field';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Textarea } from '@/components/ui/textarea';
import { listPriceLists } from '@/features/documents/api';
import { listStaff, routesApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { createCustomer, findByMobile, updateCustomer, type CustomerRow } from '../api';
import { CUSTOMER_DEFAULTS, customerSchema, digits, type CustomerInput } from '../schema';

function toForm(c: CustomerRow): CustomerInput {
  return {
    name: c.name ?? '',
    code: c.code ?? '',
    mobile1: c.mobile1 ?? '',
    mobile2: c.mobile2 ?? '',
    mobile3: c.mobile3 ?? '',
    town: c.town ?? '',
    address: c.address ?? '',
    route_id: c.route_id ?? '',
    sales_exec_id: c.sales_exec_id ?? '',
    price_group: c.price_group ?? 'default',
    price_list_id: c.price_list_id ?? '',
    credit_limit: Number(c.credit_limit ?? 0),
    opening_balance: Number(c.opening_balance ?? 0),
    whatsapp_opt_in: c.whatsapp_opt_in ?? true,
    language: c.language === 'en' ? 'en' : 'te',
    is_active: c.is_active ?? true,
  };
}

const orNull = (s: string) => (s.trim() === '' ? null : s.trim());

export function CustomerDialog({ customer, onClose }: { customer?: CustomerRow; onClose: () => void }) {
  const queryClient = useQueryClient();
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list });
  const priceLists = useQuery({ queryKey: ['pricing', 'lists'], queryFn: listPriceLists });
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const form = useForm<CustomerInput>({
    resolver: zodResolver(customerSchema),
    defaultValues: customer ? toForm(customer) : CUSTOMER_DEFAULTS,
  });
  const e = form.formState.errors;

  const save = useMutation({
    mutationFn: async (v: CustomerInput) => {
      const m1 = digits(v.mobile1);
      const dup = await findByMobile(m1, customer?.id ?? undefined);
      if (dup) throw new Error(`Mobile ${m1} already belongs to "${dup}". Open that customer instead of creating a duplicate.`);
      const values = {
        name: v.name,
        code: orNull(v.code),
        mobile1: m1,
        mobile2: orNull(digits(v.mobile2)),
        mobile3: orNull(digits(v.mobile3)),
        town: orNull(v.town),
        address: orNull(v.address),
        route_id: v.route_id || null,
        sales_exec_id: v.sales_exec_id || null,
        price_group: v.price_group || 'default',
        price_list_id: v.price_list_id || null,
        credit_limit: v.credit_limit,
        opening_balance: v.opening_balance,
        whatsapp_opt_in: v.whatsapp_opt_in,
        language: v.language,
        is_active: v.is_active,
      };
      return customer?.id ? updateCustomer(customer.id, values) : createCustomer(values);
    },
    onSuccess: async (saved) => {
      await queryClient.invalidateQueries({ queryKey: ['customers'] });
      toast({ title: `${saved.name} saved` });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not save the customer'),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{customer ? 'Edit customer' : 'New customer'}</DialogTitle>
        </DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-3 gap-3" noValidate>
          <Field label="Name / company" htmlFor="cu-name" error={e.name?.message} className="col-span-2">
            <Input id="cu-name" autoFocus {...form.register('name')} />
          </Field>
          <Field label="Ledger code" htmlFor="cu-code" error={e.code?.message}>
            <Input id="cu-code" {...form.register('code')} />
          </Field>
          <Field label="Mobile 1" htmlFor="cu-m1" error={e.mobile1?.message} help="Duplicate check key.">
            <Input id="cu-m1" inputMode="tel" {...form.register('mobile1')} />
          </Field>
          <Field label="Mobile 2" htmlFor="cu-m2" error={e.mobile2?.message}>
            <Input id="cu-m2" inputMode="tel" {...form.register('mobile2')} />
          </Field>
          <Field label="Mobile 3" htmlFor="cu-m3" error={e.mobile3?.message}>
            <Input id="cu-m3" inputMode="tel" {...form.register('mobile3')} />
          </Field>
          <Field label="City / town" htmlFor="cu-town" error={e.town?.message}>
            <Input id="cu-town" {...form.register('town')} />
          </Field>
          <Field label="Route" htmlFor="cu-route" error={e.route_id?.message}>
            <NativeSelect id="cu-route" {...form.register('route_id')}>
              <option value="">— none —</option>
              {(routes.data ?? []).filter((r) => r.is_active).map((r) => (
                <option key={r.id} value={r.id}>
                  {r.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Salesman" htmlFor="cu-se" help="Bills and collections count for their incentives. Assign a whole route under Setup → Incentives.">
            <NativeSelect id="cu-se" {...form.register('sales_exec_id')}>
              <option value="">— none —</option>
              {(staff.data ?? []).filter((s) => s.is_active && (s.role === 'sales_exec' || s.role === 'driver')).map((s) => (
                <option key={s.id} value={s.id}>
                  {s.full_name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Price list" htmlFor="cu-pl" help="Blank = the default list, then the item master.">
            <NativeSelect id="cu-pl" {...form.register('price_list_id')}>
              <option value="">— default —</option>
              {(priceLists.data ?? []).filter((p) => p.is_active).map((p) => (
                <option key={p.id ?? ''} value={p.id ?? ''}>{p.name}{p.is_default ? ' (default)' : ''}</option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Price group" htmlFor="cu-pg" error={e.price_group?.message} help="For rate overrides.">
            <Input id="cu-pg" {...form.register('price_group')} />
          </Field>
          <Field label="Message language" htmlFor="cu-lang" help="WhatsApp messages go out in this language.">
            <NativeSelect id="cu-lang" {...form.register('language')}>
              <option value="te">Telugu</option>
              <option value="en">English</option>
            </NativeSelect>
          </Field>
          <Field label="Address" htmlFor="cu-address" error={e.address?.message} className="col-span-3">
            <Textarea id="cu-address" rows={2} {...form.register('address')} />
          </Field>
          <Field label="Credit limit (₹)" htmlFor="cu-limit" error={e.credit_limit?.message}>
            <Input id="cu-limit" type="number" step="0.01" className="num" {...form.register('credit_limit')} />
          </Field>
          <Field label="Opening balance (₹)" htmlFor="cu-ob" error={e.opening_balance?.message} help="Positive = customer owes.">
            <Input id="cu-ob" type="number" step="0.01" className="num" {...form.register('opening_balance')} />
          </Field>
          <div className="flex flex-col gap-2 pt-5 text-sm">
            <label htmlFor="cu-wa" className="flex items-center gap-2">
              <Checkbox id="cu-wa" {...form.register('whatsapp_opt_in')} />
              WhatsApp messages OK
            </label>
            <label htmlFor="cu-active" className="flex items-center gap-2">
              <Checkbox id="cu-active" {...form.register('is_active')} />
              Active
            </label>
          </div>
          <DialogFooter className="col-span-3 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={save.isPending}>
              {save.isPending ? 'Saving…' : 'Save'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
