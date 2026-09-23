import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { Field } from '@/components/Field';
import { SetupNeeded } from '@/components/SetupNeeded';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { packTypesApi, uomsApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { normalizeItemCode, parsePackingFromName } from '@/lib/units';
import { createItem, getItem, itemCodeExists, nextItemCode, type ItemRow } from '../api';
import { quickItemSchema, quickItemValues, type QuickItem, type RateField } from '../quick';
import { ITEM_TYPES } from '../schema';

const norm = (s: string) => s.toUpperCase().replace(/[\s.]+/g, '');

/**
 * Add a product without leaving the bill.
 *
 * "Item creation not shown in Purchase." A product that is not on the list yet
 * stopped the bill dead: save nothing, go to Items, add it, come back and type
 * the whole bill again. So the picker offers to create what was just typed, and
 * hands the new product straight to the line that wanted it.
 *
 * `rateLabel` names the rate for the screen that opened it — a purchase wants
 * the buying rate, a bill the selling rate — and it is written to that column
 * on the product, so the next bill for it opens at the right figure.
 */
export function NewItemDialog({
  open,
  initialName,
  rateField,
  rateLabel,
  defaultType = 'finished_good',
  onClose,
  onCreated,
}: {
  open: boolean;
  /** What the person had typed in the picker when they gave up looking. */
  initialName: string;
  rateField: RateField;
  rateLabel: string;
  defaultType?: QuickItem['type'];
  onClose: () => void;
  onCreated: (item: ItemRow) => void;
}) {
  const queryClient = useQueryClient();
  const packTypes = useQuery({ queryKey: ['setup', 'pack_types'], queryFn: packTypesApi.list, enabled: open });
  const uoms = useQuery({ queryKey: ['setup', 'uoms'], queryFn: uomsApi.list, enabled: open });
  const suggested = useQuery({ queryKey: ['items', 'next-code'], queryFn: nextItemCode, enabled: open });
  const uomList = (uoms.data ?? []).filter((u) => u.is_active);
  const packList = (packTypes.data ?? []).filter((p) => p.is_active);

  const form = useForm<QuickItem>({
    resolver: zodResolver(quickItemSchema),
    defaultValues: { item_code: '', name: '', type: defaultType, pack_type_id: '', base_uom_id: '', units_per_box: 0, rate: 0 },
  });
  const { register, watch, setValue, getValues, reset, formState } = form;
  const e = formState.errors;
  const type = watch('type');
  const packTypeId = watch('pack_type_id');
  const isFinished = type === 'finished_good';

  // Opening the dialog starts it fresh, with the name the person had already
  // typed and whatever the name itself gives away — "1/- KALAJAM(12) 6" is
  // twelve pieces to a jar and six jars to a box, and re-typing that from a
  // name already on screen is how a packing gets keyed in wrong.
  useEffect(() => {
    if (!open) return;
    const parsed = parsePackingFromName(initialName);
    reset({
      item_code: '',
      name: initialName.trim(),
      type: defaultType,
      pack_type_id: '',
      base_uom_id: '',
      units_per_box: parsed.unitsPerBox ?? 0,
      rate: 0,
    });
  }, [open, initialName, defaultType, reset]);

  useEffect(() => {
    if (!open || !suggested.data || getValues('item_code')) return;
    setValue('item_code', suggested.data, { shouldDirty: false });
  }, [open, suggested.data, getValues, setValue]);

  // Raw and packing materials have no box packing: one unit is one unit.
  useEffect(() => {
    if (!isFinished) {
      setValue('units_per_box', 1);
      setValue('pack_type_id', '');
    }
  }, [isFinished, setValue]);

  // The unit follows the pack type where one matches by name (JAR → JAR), and
  // otherwise the first sensible one — a weight for a raw material, a countable
  // one for a finished good.
  useEffect(() => {
    if (!open || !uomList.length || getValues('base_uom_id')) return;
    const packCode = packList.find((p) => p.id === packTypeId)?.code ?? null;
    const byPack = packCode ? uomList.find((u) => norm(u.code) === norm(packCode)) : undefined;
    const fallback = uomList.find((u) => u.basis === (isFinished ? 'unit' : 'weight')) ?? uomList[0];
    const pick = byPack ?? fallback;
    if (pick) setValue('base_uom_id', pick.id, { shouldDirty: false });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, uoms.data, packTypes.data, packTypeId, isFinished]);

  const save = useMutation({
    mutationFn: async (v: QuickItem) => {
      const code = normalizeItemCode(v.item_code);
      if (await itemCodeExists(code)) {
        const free = await nextItemCode();
        throw new Error(`Item code ${code} is already used. Codes are unique — ${free} is free, or write ${code}A if this is a repack of ${code}.`);
      }
      const created = await createItem(quickItemValues(v, rateField));
      // Read it back through the list view: the line needs units_per_box and
      // the codes the picker shows, which the bare insert does not return.
      return getItem(created.id);
    },
    onSuccess: async (item) => {
      await queryClient.invalidateQueries({ queryKey: ['items'] });
      toast({ title: `${item.item_code} ${item.name} added` });
      onCreated(item);
      onClose();
    },
    onError: (err) => toastError(err, 'Could not add the product'),
  });

  if (!open) return null;

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>New product</DialogTitle>
          <DialogDescription>
            Enough to put it on this bill. The rest — photo, MRP, section, reorder level — can be filled in later under Items.
          </DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-2 gap-3">
          <Field label="Item code" htmlFor="ni-code" error={e.item_code?.message} help="The next serial, filled in for you.">
            <Input id="ni-code" className="uppercase" {...register('item_code')} />
          </Field>
          <Field label="Type" htmlFor="ni-type" error={e.type?.message}>
            <NativeSelect id="ni-type" {...register('type')}>
              {ITEM_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Item name" htmlFor="ni-name" error={e.name?.message} className="col-span-2" help="Exactly as the client writes it, e.g. 5/- BOONDI LADDU (12) 48.">
            <Input id="ni-name" autoFocus {...register('name')} />
          </Field>
          {isFinished && (
            <Field label="Pack type" htmlFor="ni-pack" error={e.pack_type_id?.message}>
              <NativeSelect id="ni-pack" {...register('pack_type_id')}>
                <option value="">— choose —</option>
                {packList.map((p) => <option key={p.id} value={p.id}>{p.code}{p.name ? ` — ${p.name}` : ''}</option>)}
              </NativeSelect>
              <SetupNeeded show={packTypes.isSuccess && packList.length === 0} what="pack types" tab="pack-types" where="Pack types" />
            </Field>
          )}
          <Field label="Counted in" htmlFor="ni-uom" error={e.base_uom_id?.message} help="Jar, box, packet, kg. Not a godown.">
            <NativeSelect id="ni-uom" {...register('base_uom_id')}>
              <option value="">— choose —</option>
              {uomList.map((u) => <option key={u.id} value={u.id}>{u.code} — {u.name}</option>)}
            </NativeSelect>
            <SetupNeeded show={uoms.isSuccess && uomList.length === 0} what="units" tab="units" where="Units" />
          </Field>
          {isFinished && (
            <Field label="Units per box" htmlFor="ni-upb" error={e.units_per_box?.message} help="The BOX column from the price list: 6, 8, 12, 24…">
              <Input id="ni-upb" type="number" className="num" {...register('units_per_box')} />
            </Field>
          )}
          <Field label={rateLabel} htmlFor="ni-rate" error={e.rate?.message} help="Per unit, never per box. It fills this line in.">
            <Input id="ni-rate" type="number" step="0.01" className="num" {...register('rate')} />
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
