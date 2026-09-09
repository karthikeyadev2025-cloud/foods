import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ImagePlus, Lock, Trash2 } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { useForm } from 'react-hook-form';
import { useNavigate } from 'react-router-dom';
import { Field } from '@/components/Field';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { packTypesApi, sectionsApi, uomsApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { int, money } from '@/lib/format';
import { boxRate, normalizeItemCode, parsePackingFromName, piecesPerBox } from '@/lib/units';
import { createItem, itemCodeExists, nextItemCode, updateItem, uploadItemImage, type ItemRow, type ItemUpdate } from '../api';
import { ITEM_DEFAULTS, ITEM_TYPES, itemSchema, type ItemInput } from '../schema';

const norm = (s: string) => s.toUpperCase().replace(/[\s.]+/g, '');

/**
 * The product photo. The file goes to storage as soon as it is picked, because the
 * item can only hold a URL once one exists; the form then carries that URL and the
 * save writes it. A brand-new product has no id yet, so the file is named with a
 * random one instead — the id in the filename is for humans, nothing reads it.
 */
function PhotoField({ itemId, value, onChange }: { itemId: string | null; value: string; onChange: (url: string) => void }) {
  const pick = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);

  async function take(file: File | undefined) {
    if (!file) return;
    setBusy(true);
    try {
      onChange(await uploadItemImage(itemId, file));
      toast({ title: 'Photo added', description: 'Save the product to keep it.' });
    } catch (err) {
      toastError(err, 'Could not upload the photo');
    } finally {
      setBusy(false);
      if (pick.current) pick.current.value = '';
    }
  }

  return (
    <div className="col-span-2 space-y-1">
      <span className="text-sm font-medium">Photo</span>
      <div className="flex items-start gap-3">
        {value ? (
          <img src={value} alt="" className="h-20 w-20 rounded-md border object-cover" />
        ) : (
          <div className="grid h-20 w-20 place-items-center rounded-md border border-dashed text-muted-foreground">
            <ImagePlus className="h-5 w-5" aria-hidden />
          </div>
        )}
        <div className="space-y-1">
          <input ref={pick} type="file" accept="image/jpeg,image/png,image/webp" className="hidden" onChange={(ev) => take(ev.target.files?.[0])} />
          <div className="flex gap-2">
            <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => pick.current?.click()}>
              {busy ? 'Uploading…' : value ? 'Replace' : 'Add photo'}
            </Button>
            {value && (
              <Button type="button" variant="ghost" size="icon" aria-label="Remove the photo" onClick={() => onChange('')}>
                <Trash2 />
              </Button>
            )}
          </div>
          <p className="text-xs text-muted-foreground">
            Shown on the rate card. JPG, PNG or WebP, up to 5 MB.
            {!itemId && ' It is kept when you save the product.'}
          </p>
        </div>
      </div>
    </div>
  );
}

function toForm(item: ItemRow): ItemInput {
  return {
    item_code: item.item_code ?? '',
    name: item.name ?? '',
    type: (item.type ?? 'finished_good') as ItemInput['type'],
    pack_type_id: item.pack_type_id ?? '',
    section_id: item.section_id ?? '',
    base_uom_id: item.base_uom_id ?? '',
    units_per_box: item.units_per_box ?? 0,
    pieces_per_unit: item.pieces_per_unit ?? 1,
    mrp_per_piece: Number(item.mrp_per_piece ?? 0),
    net_weight_g: Number(item.net_weight_g ?? 0),
    unit_rate: Number(item.unit_rate ?? 0),
    purchase_rate: Number(item.purchase_rate ?? 0),
    reorder_level: Number(item.reorder_level ?? 0),
    shelf_life_days: item.shelf_life_days ?? 0,
    is_active: item.is_active ?? true,
    image_url: item.image_url ?? '',
  };
}

/**
 * Add Product: the anchor screen. Every packing number and price is typed here
 * and nowhere else. Box rate and pieces per box are derived live and read-only.
 */
export function ItemForm({ item }: { item?: ItemRow }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const isEdit = Boolean(item);
  const locked = Boolean(item?.has_stock_movement);

  const packTypes = useQuery({ queryKey: ['setup', 'pack_types'], queryFn: packTypesApi.list });
  const sections = useQuery({ queryKey: ['setup', 'sections'], queryFn: sectionsApi.list });
  const uoms = useQuery({ queryKey: ['setup', 'uoms'], queryFn: uomsApi.list });

  const form = useForm<ItemInput>({
    resolver: zodResolver(itemSchema),
    defaultValues: item ? toForm(item) : ITEM_DEFAULTS,
  });
  const { register, watch, setValue, getValues, formState } = form;
  const e = formState.errors;

  const type = watch('type');
  const packTypeId = watch('pack_type_id');
  const unitsPerBox = Number(watch('units_per_box')) || 0;
  const piecesPerUnit = Number(watch('pieces_per_unit')) || 0;
  const unitRate = Number(watch('unit_rate')) || 0;
  const isFinished = type === 'finished_good';
  const packCode = packTypes.data?.find((p) => p.id === packTypeId)?.code ?? null;
  const unitLabel = packCode ? packCode.toLowerCase() : 'unit';

  // Stock unit defaults from the pack type (JAR → JAR uom), else the first unit-basis uom.
  useEffect(() => {
    if (!uoms.data?.length || getValues('base_uom_id')) return;
    const byPack = packCode ? uoms.data.find((u) => u.is_active && norm(u.code) === norm(packCode)) : undefined;
    const fallback = uoms.data.find((u) => u.is_active && u.basis === (isFinished ? 'unit' : 'weight'));
    const pick = byPack ?? fallback;
    if (pick) setValue('base_uom_id', pick.id, { shouldDirty: false });
  }, [uoms.data, packCode, isFinished, getValues, setValue]);

  /**
   * A new product opens with the next serial code already filled in, so the
   * master stays in order and nobody has to go and look up which numbers are
   * free. It is only a suggestion — the field stays editable, because a repack
   * is written 27A by hand and must not disturb the count.
   */
  const suggested = useQuery({ queryKey: ['items', 'next-code'], queryFn: nextItemCode, enabled: !isEdit });
  useEffect(() => {
    if (isEdit || !suggested.data || getValues('item_code')) return;
    setValue('item_code', suggested.data, { shouldDirty: false });
  }, [isEdit, suggested.data, getValues, setValue]);

  // Raw and packing materials have no box packing: 1 unit = 1 piece.
  useEffect(() => {
    if (!isFinished) {
      setValue('units_per_box', 1);
      setValue('pieces_per_unit', 1);
      setValue('pack_type_id', '');
    }
  }, [isFinished, setValue]);

  const prefillFromName = () => {
    if (isEdit) return;
    const parsed = parsePackingFromName(getValues('name'));
    if (parsed.unitsPerBox && !Number(getValues('units_per_box'))) setValue('units_per_box', parsed.unitsPerBox, { shouldDirty: true });
    if (parsed.piecesPerUnit && Number(getValues('pieces_per_unit')) <= 1) setValue('pieces_per_unit', parsed.piecesPerUnit, { shouldDirty: true });
    if (parsed.mrpPerPiece && !Number(getValues('mrp_per_piece'))) setValue('mrp_per_piece', parsed.mrpPerPiece, { shouldDirty: true });
  };

  const save = useMutation({
    mutationFn: async (v: ItemInput) => {
      const code = normalizeItemCode(v.item_code);
      if (await itemCodeExists(code, item?.id ?? undefined)) {
        const free = await nextItemCode();
        throw new Error(`Item code ${code} is already used. Codes are unique — ${free} is free, or write ${code}A if this is a repack of ${code}.`);
      }
      const values = {
        item_code: code,
        name: v.name,
        type: v.type,
        pack_type_id: v.pack_type_id || null,
        section_id: v.section_id || null,
        base_uom_id: v.base_uom_id,
        units_per_box: v.units_per_box,
        pieces_per_unit: v.pieces_per_unit,
        mrp_per_piece: v.mrp_per_piece || null,
        net_weight_g: v.net_weight_g || null,
        unit_rate: v.unit_rate,
        purchase_rate: v.purchase_rate,
        reorder_level: v.reorder_level,
        shelf_life_days: v.shelf_life_days || null,
        is_active: v.is_active,
        // Easy to forget, and it fails silently: the upload succeeds, the preview shows,
        // and the URL is dropped on save. Anything added to the form belongs here too.
        image_url: v.image_url || null,
      };
      if (item?.id) {
        // Never send the packing of a locked item; the DB would refuse anyway.
        const payload: ItemUpdate = { ...values };
        if (locked) delete payload.units_per_box;
        return updateItem(item.id, payload);
      }
      return createItem(values);
    },
    onSuccess: async (saved) => {
      await queryClient.invalidateQueries({ queryKey: ['items'] });
      toast({ title: `${saved.item_code} saved` });
      navigate('/items');
    },
    onError: (err) => toastError(err, 'Could not save the item'),
  });

  const derived = unitsPerBox > 0 && piecesPerUnit > 0 ? { unitsPerBox, piecesPerUnit } : null;

  return (
    <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid gap-4 lg:grid-cols-[1fr_1fr_18rem]" noValidate>
      <Card>
        <CardHeader>
          <CardTitle>Identity</CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-2 gap-3">
          <Field label="Item code" htmlFor="it-code" error={e.item_code?.message} help={isEdit ? 'Fixed once the product exists.' : 'The next serial, filled in for you. Change it for a repack — 27A, 06A.'}>
            <Input id="it-code" autoFocus={!isEdit} disabled={isEdit} className="uppercase" {...register('item_code')} />
          </Field>
          <Field label="Type" htmlFor="it-type" error={e.type?.message}>
            <NativeSelect id="it-type" {...register('type')}>
              {ITEM_TYPES.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field
            label="Item name"
            htmlFor="it-name"
            error={e.name?.message}
            className="col-span-2"
            help="Exactly as the client writes it, e.g. 5/- BOONDI LADDU (12) 48. Never re-cased."
          >
            <Input id="it-name" {...register('name', { onBlur: prefillFromName })} />
          </Field>
          {isFinished && (
            <Field label="Pack type" htmlFor="it-pack" error={e.pack_type_id?.message}>
              <NativeSelect id="it-pack" {...register('pack_type_id')}>
                <option value="">— choose —</option>
                {(packTypes.data ?? []).filter((p) => p.is_active).map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.code}
                    {p.name ? ` — ${p.name}` : ''}
                  </option>
                ))}
              </NativeSelect>
            </Field>
          )}
          <Field label="Section (mestri)" htmlFor="it-section" error={e.section_id?.message}>
            <NativeSelect id="it-section" {...register('section_id')}>
              <option value="">— none —</option>
              {(sections.data ?? []).filter((s) => s.is_active).map((s) => (
                <option key={s.id} value={s.id}>
                  {s.code ? `${s.code} ` : ''}
                  {s.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Stock kept in" htmlFor="it-uom" error={e.base_uom_id?.message} help="The unit the ledger counts.">
            <NativeSelect id="it-uom" {...register('base_uom_id')}>
              <option value="">— choose —</option>
              {(uoms.data ?? []).filter((u) => u.is_active).map((u) => (
                <option key={u.id} value={u.id}>
                  {u.code} — {u.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <label htmlFor="it-active" className="flex items-center gap-2 pt-5 text-sm">
            <Checkbox id="it-active" {...register('is_active')} />
            Active
          </label>
          <PhotoField
            itemId={item?.id ?? null}
            value={watch('image_url')}
            onChange={(url) => setValue('image_url', url, { shouldDirty: true })}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Packing & pricing</CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-2 gap-3">
          {isFinished ? (
            <>
              <Field
                label={`${packCode ? packCode + 's' : 'Units'} per box`}
                htmlFor="it-upb"
                error={e.units_per_box?.message}
                help={locked ? undefined : 'From the price list BOX column (6, 8, 12, 21, 24, 32, 48…). Required.'}
              >
                <Input id="it-upb" type="number" inputMode="numeric" className="num" disabled={locked} {...register('units_per_box')} />
              </Field>
              <Field label={`Pieces per ${unitLabel}`} htmlFor="it-ppu" error={e.pieces_per_unit?.message} help='The "(12)" in the name.'>
                <Input id="it-ppu" type="number" inputMode="numeric" className="num" {...register('pieces_per_unit')} />
              </Field>
              {locked && (
                <p className="col-span-2 flex items-start gap-2 rounded-md border border-amber-300 bg-amber-50 p-2 text-xs text-amber-900">
                  <Lock className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />
                  Packing is locked: this item already has stock movement, and stock is held in {unitLabel}s, so changing
                  it would rewrite every past stock report. To repack, create a new item code (the client&apos;s
                  convention: <span className="font-medium">{item?.item_code} NEW</span> or {item?.item_code}A).
                </p>
              )}
              <Field label="MRP per piece (₹)" htmlFor="it-mrp" error={e.mrp_per_piece?.message} help='The "5/-" prefix.'>
                <Input id="it-mrp" type="number" step="0.01" className="num" {...register('mrp_per_piece')} />
              </Field>
              <Field label="Net weight (g), loose items" htmlFor="it-wt" error={e.net_weight_g?.message}>
                <Input id="it-wt" type="number" step="0.001" className="num" {...register('net_weight_g')} />
              </Field>
            </>
          ) : (
            <p className="col-span-2 text-sm text-muted-foreground">
              Raw and packing materials are counted in their stock unit (kg, litre, piece). No box packing.
            </p>
          )}
          <Field label={`Unit rate (₹ per ${unitLabel})`} htmlFor="it-rate" error={e.unit_rate?.message} help="Never per box. Box rate is computed.">
            <Input id="it-rate" type="number" step="0.01" className="num" {...register('unit_rate')} />
          </Field>
          <Field label="Purchase rate (₹)" htmlFor="it-prate" error={e.purchase_rate?.message}>
            <Input id="it-prate" type="number" step="0.01" className="num" {...register('purchase_rate')} />
          </Field>
          <Field label="Reorder level (stock units)" htmlFor="it-reorder" error={e.reorder_level?.message}>
            <Input id="it-reorder" type="number" step="0.001" className="num" {...register('reorder_level')} />
          </Field>
          <Field label="Shelf life (days)" htmlFor="it-shelf" error={e.shelf_life_days?.message}>
            <Input id="it-shelf" type="number" inputMode="numeric" className="num" {...register('shelf_life_days')} />
          </Field>
        </CardContent>
      </Card>

      <div className="space-y-3">
        <Card className="bg-secondary/40">
          <CardHeader>
            <CardTitle className="text-sm">Derived — read only</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            {isFinished ? (
              <>
                <Derived label="Box rate" value={derived ? money(boxRate(unitRate, derived)) : '—'} hint={`${money(unitRate)} × ${int(unitsPerBox)}`} />
                <Derived label="Pieces per box" value={derived ? int(piecesPerBox(derived)) : '—'} hint={`${int(piecesPerUnit)} × ${int(unitsPerBox)}`} />
                <p className="rounded-md border bg-card p-2 text-xs">
                  {derived
                    ? `1 box = ${int(unitsPerBox)} ${unitLabel}${unitsPerBox === 1 ? '' : 's'} = ${int(piecesPerBox(derived))} pieces · box rate ${money(boxRate(unitRate, derived))}`
                    : 'Enter units per box and pieces per unit to see the packing.'}
                </p>
              </>
            ) : (
              <p className="text-xs text-muted-foreground">No packing for this type.</p>
            )}
          </CardContent>
        </Card>
        <div className="flex flex-col gap-2">
          <Button type="submit" disabled={save.isPending}>
            {save.isPending ? 'Saving…' : isEdit ? 'Save changes' : 'Add product'}
          </Button>
          <Button type="button" variant="outline" onClick={() => navigate('/items')}>
            Cancel
          </Button>
        </div>
      </div>
    </form>
  );
}

function Derived({ label, value, hint }: { label: string; value: string; hint: string }) {
  return (
    <div className="flex items-baseline justify-between gap-2">
      <span className="text-muted-foreground">{label}</span>
      <span className="text-right">
        <span className="block font-semibold tabular-nums">{value}</span>
        <span className="block text-[11px] text-muted-foreground">{hint}</span>
      </span>
    </div>
  );
}
