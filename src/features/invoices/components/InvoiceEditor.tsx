import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Printer, Trash2 } from 'lucide-react';
import { useEffect, useMemo, useRef, useState } from 'react';
import { useForm } from 'react-hook-form';
import { Link, useNavigate } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { getCustomer, searchCustomers, type CustomerRow } from '@/features/customers/api';
import { applyDiscountSchemes } from '@/features/documents/api';
import { effectiveUnitRate, searchItems, type ItemRow } from '@/features/items/api';
import { stockLocationsApi } from '@/features/setup/api';
import { listVehicles } from '@/features/vehicles/api';
import { listOpenTrips } from '@/features/vehicles/trips-api';
import { toast, toastError } from '@/hooks/use-toast';
import { amount, dateDMY, int, qty, toISODate, toNumber } from '@/lib/format';
import { amountInWords } from '@/lib/money';
import { invoiceLine, invoiceTotals } from '@/lib/units';
import {
  INVOICE_STATUSES,
  assignVehicle,
  saveInvoice,
  setInvoiceStatus,
  type InvoiceLineRow,
  type InvoiceRow,
  type InvoiceStatus,
} from '../api';
import { invoiceHeaderSchema, type DraftLine, type InvoiceHeaderForm } from '../schema';

let lineSeq = 0;
const nextKey = () => `l${++lineSeq}`;

function linesFromRows(rows: InvoiceLineRow[]): DraftLine[] {
  return rows.map((r) => ({
    key: nextKey(),
    item_id: r.item_id ?? '',
    item_code: r.item_code ?? '',
    item_name: r.item_name ?? '',
    units_per_box: Number(r.units_per_box ?? 0),
    boxes: Number(r.boxes ?? 0),
    rate: Number(r.rate ?? 0),
  }));
}

/**
 * The core screen. Column order is fixed to the client's form:
 * S.No | CODE | Item Name | Jars | Boxes | Qty | Rate | Total.
 * The operator types CODE, Boxes and Rate; Jars, Qty and Total are derived.
 */
export function InvoiceEditor({ invoice, lineRows }: { invoice?: InvoiceRow; lineRows?: InvoiceLineRow[] }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const perms = usePermissions();
  const editable = !invoice || invoice.status === 'draft';
  const canEdit = perms.canEdit('invoices') && editable;

  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const vehicles = useQuery({ queryKey: ['vehicles', 'list'], queryFn: listVehicles });
  const openTrips = useQuery({ queryKey: ['trips', 'open'], queryFn: listOpenTrips, enabled: editable });

  const form = useForm<InvoiceHeaderForm>({
    resolver: zodResolver(invoiceHeaderSchema),
    defaultValues: {
      customer_id: invoice?.customer_id ?? '',
      invoice_date: invoice?.invoice_date ?? toISODate(),
      location_id: invoice?.location_id ?? '',
      vehicle_id: invoice?.vehicle_id ?? '',
      trip_id: invoice?.trip_id ?? '',
      transport_name: invoice?.transport_name ?? '',
      lr_no: invoice?.lr_no ?? '',
      lr_date: invoice?.lr_date ?? '',
      freight: toNumber(invoice?.freight),
      discount: toNumber(invoice?.discount),
      round_off: toNumber(invoice?.round_off),
      notes: invoice?.notes ?? '',
    },
  });
  const { register, setValue, watch, formState } = form;
  const e = formState.errors;

  const [customer, setCustomer] = useState<CustomerRow | null>(null);
  useEffect(() => {
    if (invoice?.customer_id && !customer) {
      getCustomer(invoice.customer_id).then(setCustomer).catch(() => undefined);
    }
  }, [invoice?.customer_id, customer]);

  // Default location: the first godown.
  useEffect(() => {
    if (!invoice && locations.data && !form.getValues('location_id')) {
      const g = locations.data.find((l) => l.is_active && l.kind === 'godown') ?? locations.data[0];
      if (g) setValue('location_id', g.id);
    }
  }, [locations.data, invoice, form, setValue]);

  const [lines, setLines] = useState<DraftLine[]>(() => (lineRows ? linesFromRows(lineRows) : []));
  const [entryItem, setEntryItem] = useState<ItemRow | null>(null);
  const [entryBoxes, setEntryBoxes] = useState('');
  const [entryRate, setEntryRate] = useState('');
  const boxesRef = useRef<HTMLInputElement>(null);
  const rateRef = useRef<HTMLInputElement>(null);
  const codeWrapRef = useRef<HTMLDivElement>(null);
  const [cancelOpen, setCancelOpen] = useState(false);

  const invoiceDate = watch('invoice_date');
  const tripId = watch('trip_id');
  const freight = toNumber(watch('freight'));
  const discount = toNumber(watch('discount'));
  const roundOff = toNumber(watch('round_off'));

  const computed = useMemo(() => lines.map((l) => invoiceLine({ boxes: l.boxes, rate: l.rate, unitsPerBox: l.units_per_box })), [lines]);
  const totals = useMemo(() => invoiceTotals(computed), [computed]);
  const net = Math.round((totals.netAmount - discount + freight + roundOff) * 100) / 100;

  const focusCode = () => {
    const input = codeWrapRef.current?.querySelector('input');
    input?.focus();
  };

  const onItemPicked = async (item: ItemRow) => {
    let rate = toNumber(item.unit_rate);
    if (customer?.id && item.id) {
      try {
        rate = await effectiveUnitRate(item.id, customer.id, invoiceDate || toISODate());
      } catch {
        /* master rate stays */
      }
    }
    if (item.scanned && item.id && item.units_per_box) {
      // Scanned: a box code adds one box, a unit code adds one jar; repeat scans accumulate.
      const add = item.scanned === 'box' ? 1 : 1 / item.units_per_box;
      setLines((prev) => {
        const i = prev.findIndex((l) => l.item_id === item.id && l.rate === rate);
        if (i >= 0) return prev.map((l, j) => (j === i ? { ...l, boxes: Math.round((l.boxes + add) * 1000) / 1000 } : l));
        return [...prev, { key: nextKey(), item_id: item.id ?? '', item_code: item.item_code ?? '', item_name: item.name ?? '', units_per_box: item.units_per_box ?? 0, boxes: Math.round(add * 1000) / 1000, rate }];
      });
      setEntryItem(null);
      setEntryBoxes('');
      setEntryRate('');
      setTimeout(focusCode, 0);
      return;
    }
    setEntryItem(item);
    setEntryRate(rate ? String(rate) : '');
    setEntryBoxes('');
    setTimeout(() => boxesRef.current?.focus(), 0);
  };

  const addEntry = () => {
    const boxes = toNumber(entryBoxes);
    const rate = toNumber(entryRate);
    if (!entryItem?.id || !entryItem.units_per_box) return;
    if (boxes <= 0) {
      boxesRef.current?.focus();
      return;
    }
    setLines((prev) => [
      ...prev,
      {
        key: nextKey(),
        item_id: entryItem.id ?? '',
        item_code: entryItem.item_code ?? '',
        item_name: entryItem.name ?? '',
        units_per_box: entryItem.units_per_box ?? 0,
        boxes,
        rate,
      },
    ]);
    setEntryItem(null);
    setEntryBoxes('');
    setEntryRate('');
    setTimeout(focusCode, 0);
  };

  const updateLine = (key: string, patch: Partial<Pick<DraftLine, 'boxes' | 'rate'>>) =>
    setLines((prev) => prev.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  const removeLine = (key: string) => setLines((prev) => prev.filter((l) => l.key !== key));

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ['invoices'] });

  const save = useMutation({
    mutationFn: async ({ header, confirm }: { header: InvoiceHeaderForm; confirm: boolean }) => {
      if (lines.length === 0) throw new Error('Add at least one line');
      const bad = lines.find((l) => l.boxes <= 0);
      if (bad) throw new Error(`${bad.item_code}: boxes must be greater than zero`);
      const id = await saveInvoice(
        {
          id: invoice?.id ?? undefined,
          customer_id: header.customer_id,
          invoice_date: header.invoice_date,
          location_id: header.location_id,
          vehicle_id: header.vehicle_id || null,
          trip_id: header.trip_id || null,
          transport_name: header.transport_name || null,
          lr_no: header.lr_no || null,
          lr_date: header.lr_date || null,
          freight: header.freight,
          discount: header.discount,
          round_off: header.round_off,
          notes: header.notes || null,
        },
        lines.map((l) => ({ item_id: l.item_id, boxes: l.boxes, rate: l.rate })),
      );
      if (confirm) await setInvoiceStatus(id, 'confirmed');
      return { id, confirm };
    },
    onSuccess: async ({ id, confirm }) => {
      await invalidate();
      toast({ title: confirm ? 'Invoice confirmed — stock and ledger posted' : 'Draft saved' });
      navigate(`/invoices/${id}`, { replace: true });
    },
    onError: (err) => toastError(err, 'Could not save the invoice'),
  });

  const status = useMutation({
    mutationFn: (s: InvoiceStatus) => setInvoiceStatus(invoice?.id ?? '', s),
    onSuccess: async (_d, s) => {
      await invalidate();
      setCancelOpen(false);
      toast({ title: `Invoice ${s}` });
    },
    onError: (err) => toastError(err, 'Could not change status'),
  });

  const vehicle = useMutation({
    mutationFn: (vehicleId: string) => assignVehicle(invoice?.id ?? '', vehicleId || null),
    onSuccess: async () => {
      await invalidate();
      toast({ title: 'Vehicle assigned' });
    },
    onError: (err) => toastError(err, 'Could not assign the vehicle'),
  });

  const schemes = useMutation({
    mutationFn: () => applyDiscountSchemes(invoice?.id ?? ''),
    onSuccess: async (r) => {
      await invalidate();
      toast({ title: r.discount > 0 || r.free_lines.length ? `Schemes applied: discount ${amount(r.discount)}${r.free_lines.length ? `, ${r.free_lines.length} free line${r.free_lines.length === 1 ? '' : 's'}` : ''}` : 'No scheme matches these lines' });
    },
    onError: (err) => toastError(err, 'Could not apply schemes'),
  });

  const statusLabel = INVOICE_STATUSES.find((s) => s.value === invoice?.status)?.label;

  return (
    <div className="space-y-4">
      {invoice && (
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={invoice.status === 'cancelled' ? 'destructive' : invoice.status === 'draft' ? 'outline' : 'default'}>{statusLabel}</Badge>
          <span className="text-sm text-muted-foreground">
            Invoice <span className="font-medium text-foreground">{invoice.invoice_no}</span> · {dateDMY(invoice.invoice_date)}
          </span>
          <span className="ml-auto flex flex-wrap items-center gap-2">
            {invoice.status !== 'draft' && invoice.status !== 'cancelled' && (
              <Button asChild variant="outline" size="sm">
                <Link to={`/invoices/${invoice.id}/print`}>
                  <Printer /> Print
                </Link>
              </Button>
            )}
            {perms.canEdit('invoices') && invoice.status === 'confirmed' && (
              <Button size="sm" variant="secondary" onClick={() => status.mutate('dispatched')} disabled={status.isPending}>
                Mark dispatched
              </Button>
            )}
            {perms.canEdit('invoices') && invoice.status === 'dispatched' && (
              <Button size="sm" variant="secondary" onClick={() => status.mutate('delivered')} disabled={status.isPending}>
                Mark delivered
              </Button>
            )}
            {perms.canEdit('invoices') && invoice.status !== 'cancelled' && invoice.status !== 'delivered' && (
              <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setCancelOpen(true)}>
                Cancel invoice
              </Button>
            )}
          </span>
        </div>
      )}

      <form className="space-y-4" onSubmit={(ev) => ev.preventDefault()} noValidate>
        <Card>
          <CardContent className="grid grid-cols-2 gap-3 pt-4 md:grid-cols-4">
            <Field label="Customer" htmlFor="inv-customer" error={e.customer_id?.message} className="col-span-2">
              <Combobox<CustomerRow>
                id="inv-customer"
                value={customer}
                onChange={(c) => {
                  setCustomer(c);
                  setValue('customer_id', c?.id ?? '', { shouldValidate: true });
                }}
                search={searchCustomers}
                queryKey="customers"
                getKey={(c) => c.id ?? ''}
                getLabel={(c) => `${c.name ?? ''}${c.town ? ` — ${c.town}` : ''}`}
                renderOption={(c) => (
                  <span>
                    <span className="font-medium">{c.name}</span>
                    <span className="text-muted-foreground">
                      {c.town ? ` · ${c.town}` : ''}
                      {c.mobile1 ? ` · ${c.mobile1}` : ''}
                    </span>
                  </span>
                )}
                placeholder="Type name, mobile or town…"
                autoFocus={!invoice}
                disabled={!canEdit}
                eager
                onPicked={focusCode}
              />
            </Field>
            <Field label="Invoice date" htmlFor="inv-date" error={e.invoice_date?.message}>
              <Input id="inv-date" type="date" disabled={!canEdit} {...register('invoice_date')} />
            </Field>
            <Field label="Van trip (selling on the road)" htmlFor="inv-trip" help={tripId ? 'Stock leaves the van; vehicle set from the trip.' : undefined}>
              <NativeSelect id="inv-trip" disabled={!canEdit} {...register('trip_id')}>
                <option value="">— from a godown —</option>
                {(openTrips.data ?? []).map((t) => (
                  <option key={t.id ?? ''} value={t.id ?? ''}>
                    {t.vehicle_number} · {dateDMY(t.trip_date)}
                    {t.driver_name ? ` · ${t.driver_name}` : ''}
                  </option>
                ))}
              </NativeSelect>
            </Field>
            {!tripId && (
              <Field label="Stock from" htmlFor="inv-location" error={e.location_id?.message}>
                <NativeSelect id="inv-location" disabled={!canEdit} {...register('location_id')}>
                  <option value="">— choose —</option>
                  {(locations.data ?? []).filter((l) => l.is_active).map((l) => (
                    <option key={l.id} value={l.id}>
                      {l.name}
                    </option>
                  ))}
                </NativeSelect>
              </Field>
            )}
            <Field label="Transport name" htmlFor="inv-transport" error={e.transport_name?.message}>
              <Input id="inv-transport" disabled={!canEdit} {...register('transport_name')} />
            </Field>
            <Field label="L.R. no." htmlFor="inv-lr" error={e.lr_no?.message}>
              <Input id="inv-lr" disabled={!canEdit} {...register('lr_no')} />
            </Field>
            <Field label="L.R. date" htmlFor="inv-lrdate" error={e.lr_date?.message}>
              <Input id="inv-lrdate" type="date" disabled={!canEdit} {...register('lr_date')} />
            </Field>
            <Field label="Freight (₹)" htmlFor="inv-freight" error={e.freight?.message}>
              <Input id="inv-freight" type="number" step="0.01" className="num" disabled={!canEdit} {...register('freight')} />
            </Field>
            {invoice && (
              <Field label="Vehicle (assigned after creation)" htmlFor="inv-vehicle" className="col-span-2">
                <NativeSelect
                  id="inv-vehicle"
                  value={invoice.vehicle_id ?? ''}
                  disabled={!perms.canEdit('invoices') || invoice.status === 'cancelled' || vehicle.isPending}
                  onChange={(ev) => vehicle.mutate(ev.target.value)}
                >
                  <option value="">— not assigned —</option>
                  {(vehicles.data ?? []).filter((v) => v.is_active || v.id === invoice.vehicle_id).map((v) => (
                    <option key={v.id} value={v.id ?? ''}>
                      {v.vehicle_number}
                      {v.driver_name ? ` — ${v.driver_name}` : ''}
                    </option>
                  ))}
                </NativeSelect>
              </Field>
            )}
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
                    <TableHead className="w-12">S.No</TableHead>
                    <TableHead className="w-40">CODE</TableHead>
                    <TableHead>Item Name</TableHead>
                    <TableHead className="w-20 text-right">Jars</TableHead>
                    <TableHead className="w-24 text-right">Boxes</TableHead>
                    <TableHead className="w-24 text-right">Qty</TableHead>
                    <TableHead className="w-28 text-right">Rate</TableHead>
                    <TableHead className="w-32 text-right">Total</TableHead>
                    {canEdit && <TableHead className="w-10" />}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {lines.map((l, i) => {
                    const c = computed[i];
                    return (
                      <TableRow key={l.key}>
                        <TableCell className="num">{i + 1}</TableCell>
                        <TableCell className="font-medium">{l.item_code}</TableCell>
                        <TableCell>{l.item_name}</TableCell>
                        <TableCell className="num text-muted-foreground">{qty(l.units_per_box)}</TableCell>
                        <TableCell className="num">
                          {canEdit ? (
                            <Input
                              type="number"
                              step="0.001"
                              inputMode="decimal"
                              className="num h-8"
                              aria-label={`Boxes for ${l.item_code}`}
                              value={l.boxes}
                              onChange={(ev) => updateLine(l.key, { boxes: toNumber(ev.target.value) })}
                            />
                          ) : (
                            qty(l.boxes)
                          )}
                        </TableCell>
                        <TableCell className="num text-muted-foreground">{qty(c?.qty)}</TableCell>
                        <TableCell className="num">
                          {canEdit ? (
                            <Input
                              type="number"
                              step="0.01"
                              inputMode="decimal"
                              className="num h-8"
                              aria-label={`Rate for ${l.item_code}`}
                              value={l.rate}
                              onChange={(ev) => updateLine(l.key, { rate: toNumber(ev.target.value) })}
                            />
                          ) : (
                            amount(l.rate)
                          )}
                        </TableCell>
                        <TableCell className="num font-medium">{amount(c?.total)}</TableCell>
                        {canEdit && (
                          <TableCell>
                            <Button type="button" variant="ghost" size="icon" aria-label={`Remove ${l.item_code}`} onClick={() => removeLine(l.key)}>
                              <Trash2 className="text-destructive" />
                            </Button>
                          </TableCell>
                        )}
                      </TableRow>
                    );
                  })}

                  {canEdit && (
                    <TableRow className="bg-muted/30">
                      <TableCell className="num text-muted-foreground">{lines.length + 1}</TableCell>
                      <TableCell>
                        <div ref={codeWrapRef}>
                          <Combobox<ItemRow>
                            value={entryItem}
                            onChange={setEntryItem}
                            search={(q) => searchItems(q, { finishedOnly: true })}
                            queryKey="items"
                            getKey={(it) => it.id ?? ''}
                            getLabel={(it) => it.item_code ?? ''}
                            renderOption={(it) => (
                              <span>
                                <span className="font-medium">{it.item_code}</span> {it.name}
                                <span className="text-muted-foreground"> · {it.units_per_box}/box · ₹{amount(it.unit_rate)}</span>
                              </span>
                            )}
                            placeholder="CODE"
                            aria-label="Item code"
                            onPicked={onItemPicked}
                          />
                        </div>
                      </TableCell>
                      <TableCell className="text-muted-foreground">{entryItem?.name ?? 'Type a code or name, Enter to pick'}</TableCell>
                      <TableCell className="num text-muted-foreground">{entryItem ? qty(entryItem.units_per_box) : ''}</TableCell>
                      <TableCell>
                        <Input
                          ref={boxesRef}
                          type="number"
                          step="0.001"
                          inputMode="decimal"
                          className="num h-8"
                          aria-label="Boxes"
                          value={entryBoxes}
                          onChange={(ev) => setEntryBoxes(ev.target.value)}
                          onKeyDown={(ev) => {
                            if (ev.key === 'Enter') {
                              ev.preventDefault();
                              rateRef.current?.focus();
                            }
                          }}
                          disabled={!entryItem}
                        />
                      </TableCell>
                      <TableCell className="num text-muted-foreground">
                        {entryItem && entryBoxes ? qty(toNumber(entryBoxes) * (entryItem.units_per_box ?? 0)) : ''}
                      </TableCell>
                      <TableCell>
                        <Input
                          ref={rateRef}
                          type="number"
                          step="0.01"
                          inputMode="decimal"
                          className="num h-8"
                          aria-label="Rate"
                          value={entryRate}
                          onChange={(ev) => setEntryRate(ev.target.value)}
                          onKeyDown={(ev) => {
                            if (ev.key === 'Enter') {
                              ev.preventDefault();
                              addEntry();
                            }
                          }}
                          disabled={!entryItem}
                        />
                      </TableCell>
                      <TableCell className="num text-muted-foreground">
                        {entryItem && entryBoxes ? amount(toNumber(entryBoxes) * (entryItem.units_per_box ?? 0) * toNumber(entryRate)) : ''}
                      </TableCell>
                      <TableCell>
                        <Button type="button" size="sm" variant="secondary" onClick={addEntry} disabled={!entryItem}>
                          Add
                        </Button>
                      </TableCell>
                    </TableRow>
                  )}
                </TableBody>
                <TableFooter>
                  <TableRow>
                    <TableCell colSpan={4} className="text-right">
                      Total
                    </TableCell>
                    <TableCell className="num">{qty(totals.totalBoxes)}</TableCell>
                    <TableCell className="num">{int(totals.totalQty)}</TableCell>
                    <TableCell />
                    <TableCell className="num">{amount(totals.netAmount)}</TableCell>
                    {canEdit && <TableCell />}
                  </TableRow>
                </TableFooter>
              </Table>
            </div>
            {canEdit && (
              <p className="mt-2 text-xs text-muted-foreground">
                Type CODE → Enter → Boxes → Enter → Rate → Enter adds the line. Jars, Qty and Total come from the item master. Scanning a barcode into CODE adds a box (or a jar) straight away.
              </p>
            )}
          </CardContent>
        </Card>

        <div className="grid gap-4 md:grid-cols-[1fr_20rem]">
          <Card>
            <CardContent className="grid grid-cols-2 gap-3 pt-4">
              <Field label="Notes" htmlFor="inv-notes" className="col-span-2">
                <Input id="inv-notes" disabled={!canEdit} {...register('notes')} />
              </Field>
              <Field label="Discount (₹)" htmlFor="inv-discount" error={e.discount?.message}>
                <Input id="inv-discount" type="number" step="0.01" className="num" disabled={!canEdit} {...register('discount')} />
              </Field>
              <Field label="Round off (₹)" htmlFor="inv-round" error={e.round_off?.message}>
                <Input id="inv-round" type="number" step="0.01" className="num" disabled={!canEdit} {...register('round_off')} />
              </Field>
            </CardContent>
          </Card>
          <Card className="bg-secondary/40">
            <CardContent className="space-y-1 pt-4 text-sm">
              <Row label="Subtotal" value={amount(totals.netAmount)} />
              {discount > 0 && <Row label="Discount" value={`- ${amount(discount)}`} />}
              {freight > 0 && <Row label="Freight" value={amount(freight)} />}
              {roundOff !== 0 && <Row label="Round off" value={amount(roundOff)} />}
              <div className="flex items-baseline justify-between border-t pt-1 text-base font-semibold">
                <span>Net Amount</span>
                <span className="tabular-nums">{amount(net)}</span>
              </div>
              <p className="text-xs text-muted-foreground">{amountInWords(net)}</p>
            </CardContent>
          </Card>
        </div>

        {canEdit && (
          <div className="flex flex-wrap items-center justify-end gap-2">
            <Button type="button" variant="outline" onClick={() => navigate('/invoices')}>
              Back
            </Button>
            {invoice?.status === 'draft' && (
              <Button type="button" variant="outline" disabled={schemes.isPending} onClick={() => schemes.mutate()} title="Quantity discounts and free boxes from Pricing → Discount schemes. Save the draft first.">
                Apply schemes
              </Button>
            )}
            <Button
              type="button"
              variant="secondary"
              disabled={save.isPending}
              onClick={form.handleSubmit((h) => save.mutate({ header: h, confirm: false }))}
            >
              Save draft
            </Button>
            <Button type="button" disabled={save.isPending} onClick={form.handleSubmit((h) => save.mutate({ header: h, confirm: true }))}>
              {save.isPending ? 'Saving…' : 'Save & confirm'}
            </Button>
          </div>
        )}
      </form>

      <Dialog open={cancelOpen} onOpenChange={setCancelOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Cancel invoice {invoice?.invoice_no}?</DialogTitle>
            <DialogDescription>
              Stock comes back with a reversing ledger row and the journal entry is reversed. Not possible while receipts or
              returns are recorded against it.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCancelOpen(false)}>
              Keep it
            </Button>
            <Button variant="destructive" onClick={() => status.mutate('cancelled')} disabled={status.isPending}>
              Cancel invoice
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between">
      <span className="text-muted-foreground">{label}</span>
      <span className="tabular-nums">{value}</span>
    </div>
  );
}
