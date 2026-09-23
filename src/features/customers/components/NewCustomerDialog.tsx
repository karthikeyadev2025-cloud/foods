import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { Field } from '@/components/Field';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { routesApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { createCustomer, getCustomer, searchCustomers, type CustomerRow } from '../api';
import { quickCustomerSchema, quickCustomerValues, type QuickCustomer } from '../quick';

/**
 * Add a customer without leaving the bill.
 *
 * Same idea as the product dialog: a name the picker could not find used to
 * mean abandoning a half-typed document, going to Customers, and starting
 * again. Here it is created and handed straight to the screen that wanted it.
 */
export function NewCustomerDialog({
  open,
  initialName,
  onClose,
  onCreated,
}: {
  open: boolean;
  /** What was typed in the picker when they gave up looking. */
  initialName: string;
  onClose: () => void;
  onCreated: (customer: CustomerRow) => void;
}) {
  const queryClient = useQueryClient();
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list, enabled: open });

  const form = useForm<QuickCustomer>({
    resolver: zodResolver(quickCustomerSchema),
    defaultValues: { name: '', mobile1: '', town: '', route_id: '' },
  });
  const { register, reset, formState } = form;
  const e = formState.errors;

  // A picker searches name, mobile AND town, so what was typed could be any of
  // them. A run of digits is a phone number; anything else is a name.
  useEffect(() => {
    if (!open) return;
    const typed = initialName.trim();
    const isPhone = /^[\d\s+-]{6,}$/.test(typed);
    reset({ name: isPhone ? '' : typed, mobile1: isPhone ? typed : '', town: '', route_id: '' });
  }, [open, initialName, reset]);

  const save = useMutation({
    mutationFn: async (v: QuickCustomer) => {
      // The mobile is the duplicate check on the full form, so it is the
      // duplicate check here. Two rows for one shop means two ledgers, and the
      // money goes to whichever one the next person happens to pick.
      const digits = v.mobile1.replace(/\D/g, '');
      const hit = (await searchCustomers(digits)).find((c) => (c.mobile1 ?? '').replace(/\D/g, '') === digits);
      if (hit) throw new Error(`${hit.name}${hit.town ? ` (${hit.town})` : ''} already has this number. Pick them from the list instead.`);
      const created = await createCustomer(quickCustomerValues(v));
      // Read back through the list view: the screen needs the outstanding and
      // the route name, which the bare insert does not return.
      return getCustomer(created.id);
    },
    onSuccess: async (customer) => {
      await queryClient.invalidateQueries({ queryKey: ['customers'] });
      toast({ title: `${customer.name} added` });
      onCreated(customer);
      onClose();
    },
    onError: (err) => toastError(err, 'Could not add the customer'),
  });

  if (!open) return null;

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>New customer</DialogTitle>
          <DialogDescription>
            Enough to raise this bill and to find them again. Credit limit, price group and opening balance are on the
            Customers screen.
          </DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-2 gap-3">
          <Field label="Name" htmlFor="nc-name" error={e.name?.message} className="col-span-2">
            <Input id="nc-name" autoFocus {...register('name')} />
          </Field>
          <Field label="Mobile" htmlFor="nc-mobile" error={e.mobile1?.message} help="Required — it is how a repeat is spotted.">
            <Input id="nc-mobile" inputMode="tel" {...register('mobile1')} />
          </Field>
          <Field label="Town" htmlFor="nc-town" error={e.town?.message}>
            <Input id="nc-town" {...register('town')} />
          </Field>
          <Field label="Route" htmlFor="nc-route" error={e.route_id?.message} className="col-span-2" help="The van line they are on. Can be set later.">
            <NativeSelect id="nc-route" {...register('route_id')}>
              <option value="">— none —</option>
              {(routes.data ?? []).filter((r) => r.is_active).map((r) => (
                <option key={r.id} value={r.id}>{r.name}</option>
              ))}
            </NativeSelect>
          </Field>
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
          <Button type="button" onClick={form.handleSubmit((v) => save.mutate(v))} disabled={save.isPending}>
            {save.isPending ? 'Adding…' : 'Add and use'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
