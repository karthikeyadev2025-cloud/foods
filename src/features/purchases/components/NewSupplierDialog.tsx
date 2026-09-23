import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { Field } from '@/components/Field';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { toast, toastError } from '@/hooks/use-toast';
import { createSupplier, searchSuppliers, type SupplierRow } from '../api';
import { quickSupplierSchema, quickSupplierValues, type QuickSupplier } from '../quick';

/**
 * Add a supplier without leaving the purchase.
 *
 * A lorry arrives from somebody the shop has not bought from before. That
 * should cost a name and a phone number, not an abandoned bill.
 */
export function NewSupplierDialog({
  open,
  initialName,
  onClose,
  onCreated,
}: {
  open: boolean;
  initialName: string;
  onClose: () => void;
  onCreated: (supplier: SupplierRow) => void;
}) {
  const queryClient = useQueryClient();

  const form = useForm<QuickSupplier>({
    resolver: zodResolver(quickSupplierSchema),
    defaultValues: { name: '', mobile1: '', town: '' },
  });
  const { register, reset, formState } = form;
  const e = formState.errors;

  useEffect(() => {
    if (!open) return;
    const typed = initialName.trim();
    const isPhone = /^[\d\s+-]{6,}$/.test(typed);
    reset({ name: isPhone ? '' : typed, mobile1: isPhone ? typed : '', town: '' });
  }, [open, initialName, reset]);

  const save = useMutation({
    mutationFn: async (v: QuickSupplier) => {
      // Two rows for one supplier means two payable balances, and neither of
      // them is what the shop owes. Matched on the name, since a supplier is
      // allowed to have no number.
      const name = v.name.trim().toUpperCase();
      const hit = (await searchSuppliers(v.name.trim())).find((s) => (s.name ?? '').trim().toUpperCase() === name);
      if (hit) throw new Error(`${hit.name} is already a supplier. Pick them from the list instead.`);
      return createSupplier(quickSupplierValues(v));
    },
    onSuccess: async (supplier) => {
      await queryClient.invalidateQueries({ queryKey: ['suppliers'] });
      toast({ title: `${supplier.name} added` });
      // Straight onto the bill. The payable is zero until this purchase saves,
      // so nothing is lost by not reading it back through the list view.
      onCreated({ id: supplier.id, name: supplier.name, town: supplier.town, mobile1: supplier.mobile1, payable: 0 } as SupplierRow);
      onClose();
    },
    onError: (err) => toastError(err, 'Could not add the supplier'),
  });

  if (!open) return null;

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>New supplier</DialogTitle>
          <DialogDescription>
            Enough to enter this bill. What the shop already owes them belongs on the Suppliers screen, off a real
            statement.
          </DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-2 gap-3">
          <Field label="Name" htmlFor="ns-name" error={e.name?.message} className="col-span-2">
            <Input id="ns-name" autoFocus {...register('name')} />
          </Field>
          <Field label="Mobile" htmlFor="ns-mobile" error={e.mobile1?.message} help="Leave blank if their bill has none.">
            <Input id="ns-mobile" inputMode="tel" {...register('mobile1')} />
          </Field>
          <Field label="Town" htmlFor="ns-town" error={e.town?.message}>
            <Input id="ns-town" {...register('town')} />
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
