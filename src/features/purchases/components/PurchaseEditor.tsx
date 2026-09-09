import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Trash2 } from 'lucide-react';
import { useEffect, useMemo, useRef, useState } from 'react';
import { useForm } from 'react-hook-form';
import { useNavigate } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { searchItems, type ItemRow } from '@/features/items/api';
import { stockLocationsApi, uomsApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { amount, qty, toISODate, toNumber } from '@/lib/format';
import { round } from '@/lib/format';
import { savePurchase, searchSuppliers, type SupplierRow } from '../api';
import { purchaseHeaderSchema, type PurchaseDraftLine, type PurchaseHeaderForm } from '../schema';

let seq = 0;

export function PurchaseEditor() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const uoms = useQuery({ queryKey: ['setup', 'uoms'], queryFn: uomsApi.list });
  const [supplier, setSupplier] = useState<SupplierRow | null>(null);
  const [lines, setLines] = useState<PurchaseDraftLine[]>([]);
  const [entryItem, setEntryItem] = useState<ItemRow | null>(null);
  const [entryQty, setEntryQty] = useState('');
  const [entryUom, setEntryUom] = useState('');
  const [entryRate, setEntryRate] = useState('');
  const qtyRef = useRef<HTMLInputElement>(null);
  const rateRef = useRef<HTMLInputElement>(null);
  const codeWrapRef = useRef<HTMLDivElement>(null);

  const form = useForm<PurchaseHeaderForm>({
    resolver: zodResolver(purchaseHeaderSchema),
    defaultValues: { supplier_id: '', bill_no: '', bill_date: toISODate(), location_id: '', other_charges: 0, paid_amount: 0, notes: '' },
  });
  const { register, setValue, watch, formState } = form;
  const e = formState.errors;

  useEffect(() => {
    if (locations.data && !form.getValues('location_id')) {
      const g = locations.data.find((l) => l.is_active && l.kind === 'godown') ?? locations.data[0];
      if (g) setValue('location_id', g.id);
    }
  }, [locations.data, form, setValue]);

  const subtotal = useMemo(() => round(lines.reduce((s, l) => s + round(l.qty * l.rate, 2), 0), 2), [lines]);
  const other = toNumber(watch('other_charges'));
  const total = round(subtotal + other, 2);

  const focusCode = () => codeWrapRef.current?.querySelector('input')?.focus();

  const onItemPicked = (item: ItemRow) => {
    setEntryItem(item);
    setEntryUom(item.base_uom_id ?? '');
    setEntryRate(toNumber(item.purchase_rate) ? String(toNumber(item.purchase_rate)) : '');
    setEntryQty('');
    setTimeout(() => qtyRef.current?.focus(), 0);
  };

  const addEntry = () => {
    const q = toNumber(entryQty);
    if (!entryItem?.id || q <= 0 || !entryUom) {
      qtyRef.current?.focus();
      return;
    }
    setLines((prev) => [
      ...prev,
      { key: `p${++seq}`, item_id: entryItem.id ?? '', item_code: entryItem.item_code ?? '', item_name: entryItem.name ?? '', uom_id: entryUom, qty: q, rate: toNumber(entryRate) },
    ]);
    setEntryItem(null);
    setEntryQty('');
    setEntryRate('');
    setTimeout(focusCode, 0);
  };

  const save = useMutation({
    mutationFn: async (h: PurchaseHeaderForm) => {
      if (lines.length === 0) throw new Error('Add at least one line');
      if (h.paid_amount > total) throw new Error('Paid amount exceeds the bill total');
      return savePurchase(
        {
          supplier_id: h.supplier_id || null,
          bill_no: h.bill_no || null,
          bill_date: h.bill_date,
          location_id: h.location_id,
          other_charges: h.other_charges,
          paid_amount: h.paid_amount,
          notes: h.notes || null,
        },
        lines.map((l) => ({ item_id: l.item_id, qty: l.qty, uom_id: l.uom_id, rate: l.rate })),
      );
    },
    onSuccess: async (id) => {
      await queryClient.invalidateQueries({ queryKey: ['purchases'] });
      await queryClient.invalidateQueries({ queryKey: ['items'] });
      toast({ title: 'Purchase saved — stock and ledger posted' });
      navigate(`/purchases/${id}`, { replace: true });
    },
    onError: (err) => toastError(err, 'Could not save the purchase'),
  });

  const uomCode = (id: string) => uoms.data?.find((u) => u.id === id)?.code ?? '';

  return (
    <form className="space-y-4" onSubmit={form.handleSubmit((h) => save.mutate(h))} noValidate>
      <Card>
        <CardContent className="grid grid-cols-2 gap-3 pt-4 md:grid-cols-4">
          <Field label="Supplier" htmlFor="pu-supplier" error={e.supplier_id?.message} className="col-span-2" help="Leave blank for a cash purchase.">
            <Combobox<SupplierRow>
              id="pu-supplier"
              value={supplier}
              onChange={(s) => {
                setSupplier(s);
                setValue('supplier_id', s?.id ?? '');
              }}
              search={searchSuppliers}
              queryKey="suppliers"
              getKey={(s) => s.id ?? ''}
              getLabel={(s) => s.name ?? ''}
              renderOption={(s) => (
                <span>
                  <span className="font-medium">{s.name}</span>
                  <span className="text-muted-foreground">{s.town ? ` · ${s.town}` : ''} · payable ₹{amount(s.payable)}</span>
                </span>
              )}
              placeholder="Type a supplier…"
              autoFocus
              eager
              onPicked={focusCode}
            />
          </Field>
          <Field label="Bill no." htmlFor="pu-bill" error={e.bill_no?.message} help="Leave blank and it is numbered for you. Type the supplier's own number when their bill has one.">
            <Input id="pu-bill" placeholder="Numbered automatically" {...register('bill_no')} />
          </Field>
          <Field label="Bill date" htmlFor="pu-date" error={e.bill_date?.message}>
            <Input id="pu-date" type="date" {...register('bill_date')} />
          </Field>
          <Field label="Into godown" htmlFor="pu-location" error={e.location_id?.message}>
            <NativeSelect id="pu-location" {...register('location_id')}>
              <option value="">— choose —</option>
              {(locations.data ?? []).filter((l) => l.is_active && l.kind !== 'vehicle').map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Other charges (₹)" htmlFor="pu-other" error={e.other_charges?.message}>
            <Input id="pu-other" type="number" step="0.01" className="num" {...register('other_charges')} />
          </Field>
          <Field label="Paid now (₹)" htmlFor="pu-paid" error={e.paid_amount?.message} help="Cash paid on the spot.">
            <Input id="pu-paid" type="number" step="0.01" className="num" {...register('paid_amount')} />
          </Field>
          <Field label="Notes" htmlFor="pu-notes" error={e.notes?.message}>
            <Input id="pu-notes" {...register('notes')} />
          </Field>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-base">Lines</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="rounded-md border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-10">#</TableHead>
                  <TableHead className="w-40">Item</TableHead>
                  <TableHead>Name</TableHead>
                  <TableHead className="w-28 text-right">Qty</TableHead>
                  <TableHead className="w-28">Unit</TableHead>
                  <TableHead className="w-28 text-right">Rate</TableHead>
                  <TableHead className="w-32 text-right">Amount</TableHead>
                  <TableHead className="w-10" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {lines.map((l, i) => (
                  <TableRow key={l.key}>
                    <TableCell className="num">{i + 1}</TableCell>
                    <TableCell className="font-medium">{l.item_code}</TableCell>
                    <TableCell>{l.item_name}</TableCell>
                    <TableCell className="num">{qty(l.qty, 3)}</TableCell>
                    <TableCell>{uomCode(l.uom_id)}</TableCell>
                    <TableCell className="num">{amount(l.rate)}</TableCell>
                    <TableCell className="num font-medium">{amount(l.qty * l.rate)}</TableCell>
                    <TableCell>
                      <Button type="button" variant="ghost" size="icon" aria-label={`Remove ${l.item_code}`} onClick={() => setLines((p) => p.filter((x) => x.key !== l.key))}>
                        <Trash2 className="text-destructive" />
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                <TableRow className="bg-muted/30">
                  <TableCell className="num text-muted-foreground">{lines.length + 1}</TableCell>
                  <TableCell>
                    <div ref={codeWrapRef}>
                      <Combobox<ItemRow>
                        value={entryItem}
                        onChange={setEntryItem}
                        search={(q) => searchItems(q)}
                        queryKey="items-all"
                        getKey={(it) => it.id ?? ''}
                        getLabel={(it) => it.item_code ?? ''}
                        renderOption={(it) => (
                          <span>
                            <span className="font-medium">{it.item_code}</span> {it.name}
                            <span className="text-muted-foreground"> · {it.type}</span>
                          </span>
                        )}
                        placeholder="Code or name"
                        aria-label="Item"
                        onPicked={onItemPicked}
                      />
                    </div>
                  </TableCell>
                  <TableCell className="text-muted-foreground">{entryItem?.name ?? ''}</TableCell>
                  <TableCell>
                    <Input ref={qtyRef} type="number" step="0.001" inputMode="decimal" className="num h-8" aria-label="Quantity" value={entryQty} onChange={(ev) => setEntryQty(ev.target.value)} disabled={!entryItem}
                      onKeyDown={(ev) => { if (ev.key === 'Enter') { ev.preventDefault(); rateRef.current?.focus(); } }} />
                  </TableCell>
                  <TableCell>
                    <NativeSelect aria-label="Unit" className="h-8" value={entryUom} onChange={(ev) => setEntryUom(ev.target.value)} disabled={!entryItem}>
                      {(uoms.data ?? []).filter((u) => u.is_active).map((u) => (
                        <option key={u.id} value={u.id}>
                          {u.code}
                        </option>
                      ))}
                    </NativeSelect>
                  </TableCell>
                  <TableCell>
                    <Input ref={rateRef} type="number" step="0.01" inputMode="decimal" className="num h-8" aria-label="Rate" value={entryRate} onChange={(ev) => setEntryRate(ev.target.value)} disabled={!entryItem}
                      onKeyDown={(ev) => { if (ev.key === 'Enter') { ev.preventDefault(); addEntry(); } }} />
                  </TableCell>
                  <TableCell className="num text-muted-foreground">{entryItem && entryQty ? amount(toNumber(entryQty) * toNumber(entryRate)) : ''}</TableCell>
                  <TableCell>
                    <Button type="button" size="sm" variant="secondary" onClick={addEntry} disabled={!entryItem}>
                      Add
                    </Button>
                  </TableCell>
                </TableRow>
              </TableBody>
              <TableFooter>
                <TableRow>
                  <TableCell colSpan={6} className="text-right">Subtotal</TableCell>
                  <TableCell className="num">{amount(subtotal)}</TableCell>
                  <TableCell />
                </TableRow>
                <TableRow>
                  <TableCell colSpan={6} className="text-right font-semibold">Total (with other charges)</TableCell>
                  <TableCell className="num font-semibold">{amount(total)}</TableCell>
                  <TableCell />
                </TableRow>
              </TableFooter>
            </Table>
          </div>
        </CardContent>
      </Card>

      <div className="flex justify-end gap-2">
        <Button type="button" variant="outline" onClick={() => navigate('/purchases')}>
          Cancel
        </Button>
        <Button type="submit" disabled={save.isPending}>
          {save.isPending ? 'Saving…' : 'Save purchase'}
        </Button>
      </div>
    </form>
  );
}
