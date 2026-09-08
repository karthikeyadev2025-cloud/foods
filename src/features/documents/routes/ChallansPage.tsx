import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, FileCheck, Plus, Printer } from 'lucide-react';
import { SalesDocPrint } from '@/components/print/SalesDocPrint';
import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { getCustomer, searchCustomers, type CustomerRow } from '@/features/customers/api';
import { getPrintTemplate, stockLocationsApi } from '@/features/setup/api';
import { listVehicles } from '@/features/vehicles/api';
import { useDebounced } from '@/hooks/use-debounced';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { dateDMY, qty, toISODate, toNumber } from '@/lib/format';
import { cancelChallan, convertChallan, getChallan, getChallanLines, listChallans, nextLineKey, saveChallan, stateTone, type ChallanRow, type DocLine, type DocState } from '../api';
import { DocLines } from '../components/DocLines';

export function ChallansPage() {
  const navigate = useNavigate();
  const perms = usePermissions();
  const [search, setSearch] = useState('');
  const [state, setState] = useState<DocState | ''>('');
  const debounced = useDebounced(search);
  const rows = useQuery({ queryKey: ['challans', state, debounced], queryFn: () => listChallans({ state, search: debounced }) });
  const list = rows.data ?? [];
  return (
    <div className="space-y-3">
      <PageHeader title="Delivery challans" description="Goods that left before a bill. Stock moves when the challan is saved; converting bills it as a confirmed invoice."
        actions={<><Button variant="outline" size="sm" onClick={() => exportToExcel('challans', list.map((r) => ({ 'Challan no.': r.challan_no, Date: dateDMY(r.challan_date), Customer: r.customer_name, Town: r.customer_town, From: r.location_name, Vehicle: r.vehicle_number, Boxes: toNumber(r.total_boxes), State: r.state, Invoice: r.invoice_no })), 'Challans')} disabled={!list.length}><Download /> Excel</Button>{perms.canEdit('invoices') && <Button asChild size="sm"><Link to="/challans/new"><Plus /> New challan</Link></Button>}</>} />
      <div className="flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Challan no., customer…" aria-label="Search" className="h-8 w-60" value={search} onChange={(e) => setSearch(e.target.value)} />
        <NativeSelect aria-label="State" className="h-8 w-36" value={state} onChange={(e) => setState(e.target.value as DocState | '')}><option value="">All states</option><option value="open">Open (unbilled)</option><option value="converted">Billed</option><option value="cancelled">Cancelled</option></NativeSelect>
      </div>
      {rows.isLoading ? <Spinner /> : rows.error ? <p role="alert" className="text-sm text-destructive">{rows.error.message}</p> : !list.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No challans.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>No.</TableHead><TableHead>Date</TableHead><TableHead>Customer</TableHead><TableHead>From</TableHead><TableHead>Vehicle</TableHead><TableHead className="text-right">Boxes</TableHead><TableHead>State</TableHead></TableRow></TableHeader>
            <TableBody>{list.map((r) => <TableRow key={r.id ?? ''} className="cursor-pointer" tabIndex={0} onClick={() => navigate(`/challans/${r.id}`)} onKeyDown={(ev) => ev.key === 'Enter' && navigate(`/challans/${r.id}`)}><TableCell className="font-medium">{r.challan_no}</TableCell><TableCell>{dateDMY(r.challan_date)}</TableCell><TableCell>{r.customer_name}<div className="text-xs text-muted-foreground">{r.customer_town}</div></TableCell><TableCell className="text-muted-foreground">{r.location_name}</TableCell><TableCell className="text-muted-foreground">{r.vehicle_number ?? '—'}</TableCell><TableCell className="num">{qty(r.total_boxes)}</TableCell><TableCell><Badge variant={stateTone[r.state ?? 'open']}>{r.state === 'converted' ? 'billed' : r.state}</Badge>{r.invoice_no && <div className="text-xs text-muted-foreground">{r.invoice_no}</div>}</TableCell></TableRow>)}</TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}

export function ChallanEditPage() {
  const { id } = useParams();
  const isNew = !id || id === 'new';
  const challan = useQuery({ queryKey: ['challans', 'one', id], queryFn: () => getChallan(id ?? ''), enabled: !isNew });
  const lines = useQuery({ queryKey: ['challans', 'lines', id], queryFn: () => getChallanLines(id ?? ''), enabled: !isNew });
  if (!isNew && (challan.isLoading || lines.isLoading)) return <Spinner />;
  if (!isNew && (!challan.data || !lines.data)) return <p role="alert" className="text-sm text-destructive">Challan not found.</p>;
  return (
    <div className="space-y-4">
      <PageHeader title={isNew ? 'New delivery challan' : `Challan ${challan.data?.challan_no}`} actions={<Button asChild variant="ghost" size="sm"><Link to="/challans">← Challans</Link></Button>} />
      <ChallanEditor key={`${challan.data?.id ?? 'new'}-${challan.data?.state ?? ''}`} challan={challan.data ?? undefined} initialLines={(lines.data ?? []).map((l) => ({ key: nextLineKey(), item_id: l.item_id ?? '', item_code: l.item_code ?? '', item_name: l.item_name ?? '', units_per_box: toNumber(l.units_per_box), boxes: toNumber(l.boxes), rate: 0 }))} />
    </div>
  );
}

function ChallanEditor({ challan, initialLines }: { challan?: ChallanRow; initialLines: DocLine[] }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const perms = usePermissions();
  const editable = perms.canEdit('invoices') && (!challan || challan.state === 'open');
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list });
  const vehicles = useQuery({ queryKey: ['vehicles', 'list'], queryFn: listVehicles });
  const [customer, setCustomer] = useState<CustomerRow | null>(null);
  useEffect(() => { if (challan?.customer_id && !customer) getCustomer(challan.customer_id).then(setCustomer).catch(() => undefined); }, [challan?.customer_id, customer]);
  const [date, setDate] = useState(challan?.challan_date ?? toISODate());
  const [locationId, setLocationId] = useState(challan?.location_id ?? '');
  const [vehicleId, setVehicleId] = useState(challan?.vehicle_id ?? '');
  const [notes, setNotes] = useState(challan?.notes ?? '');
  const [lines, setLines] = useState<DocLine[]>(initialLines);
  const [converting, setConverting] = useState(false);
  useEffect(() => { if (!challan && locations.data && !locationId) setLocationId(locations.data.find((l) => l.is_active && l.kind === 'godown')?.id ?? locations.data[0]?.id ?? ''); }, [locations.data, challan, locationId]);
  const invalidate = async () => { await qc.invalidateQueries({ queryKey: ['challans'] }); await qc.invalidateQueries({ queryKey: ['stock'] }); };
  const save = useMutation({
    mutationFn: async () => {
      if (!customer?.id) throw new Error('Choose a customer');
      if (!lines.length) throw new Error('Add at least one line');
      return saveChallan({ id: challan?.id ?? undefined, customer_id: customer.id, challan_date: date, location_id: locationId, vehicle_id: vehicleId || null, notes: notes || null }, lines.map((l) => ({ item_id: l.item_id, boxes: l.boxes })));
    },
    onSuccess: async (newId) => { await invalidate(); toast({ title: 'Challan saved — stock moved' }); navigate(`/challans/${newId}`, { replace: true }); },
    onError: (err) => toastError(err, 'Could not save'),
  });
  const cancel = useMutation({
    mutationFn: () => cancelChallan(challan?.id ?? ''),
    onSuccess: async () => { await invalidate(); toast({ title: 'Challan cancelled — stock back' }); },
    onError: (err) => toastError(err, 'Could not cancel'),
  });
  return (
    <div className="space-y-4">
      {challan && (
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={stateTone[challan.state ?? 'open']}>{challan.state === 'converted' ? 'billed' : challan.state}</Badge>
          <span className="text-sm text-muted-foreground">{dateDMY(challan.challan_date)} · from {challan.location_name}{challan.invoice_no ? <> · billed as <Link to={`/invoices/${challan.invoice_id}`} className="text-primary hover:underline">{challan.invoice_no}</Link></> : null}</span>
          <span className="ml-auto flex gap-2">
            <Button asChild size="sm" variant="outline"><Link to={`/challans/${challan.id}/print`}><Printer /> Print</Link></Button>
            {perms.canEdit('invoices') && challan.state === 'open' && <Button size="sm" onClick={() => setConverting(true)}><FileCheck /> Convert to invoice</Button>}
            {perms.canEdit('invoices') && challan.state === 'open' && <Button size="sm" variant="ghost" className="text-destructive" onClick={() => cancel.mutate()} disabled={cancel.isPending}>Cancel challan</Button>}
          </span>
        </div>
      )}
      <Card>
        <CardContent className="grid grid-cols-2 gap-3 pt-4 md:grid-cols-4">
          <Field label="Customer" htmlFor="ch-cust" className="col-span-2"><Combobox<CustomerRow> id="ch-cust" value={customer} onChange={setCustomer} search={searchCustomers} queryKey="customers" getKey={(c) => c.id ?? ''} getLabel={(c) => `${c.name ?? ''}${c.town ? ` — ${c.town}` : ''}`} placeholder="Type name, mobile or town…" autoFocus={!challan} disabled={!editable} eager /></Field>
          <Field label="Date" htmlFor="ch-date"><Input id="ch-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} disabled={!editable} /></Field>
          <Field label="Goods leave from" htmlFor="ch-loc"><NativeSelect id="ch-loc" value={locationId} onChange={(e) => setLocationId(e.target.value)} disabled={!editable}><option value="">— choose —</option>{(locations.data ?? []).filter((l) => l.is_active).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</NativeSelect></Field>
          <Field label="Vehicle" htmlFor="ch-veh"><NativeSelect id="ch-veh" value={vehicleId} onChange={(e) => setVehicleId(e.target.value)} disabled={!editable}><option value="">—</option>{(vehicles.data ?? []).filter((v) => v.is_active).map((v) => <option key={v.id ?? ''} value={v.id ?? ''}>{v.vehicle_number}</option>)}</NativeSelect></Field>
          <Field label="Notes" htmlFor="ch-notes" className="col-span-3"><Input id="ch-notes" value={notes} onChange={(e) => setNotes(e.target.value)} disabled={!editable} /></Field>
        </CardContent>
      </Card>
      <DocLines lines={lines} onChange={setLines} editable={editable} customerId={customer?.id} date={date} showRate={false} />
      {editable && <div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={() => navigate('/challans')}>Back</Button><Button type="button" disabled={save.isPending} onClick={() => save.mutate()}>{save.isPending ? 'Saving…' : 'Save challan'}</Button></div>}
      {challan && converting && <ConvertChallanDialog challan={challan} onClose={() => setConverting(false)} />}
    </div>
  );
}

function ConvertChallanDialog({ challan, onClose }: { challan: ChallanRow; onClose: () => void }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [date, setDate] = useState(toISODate());
  const [transport, setTransport] = useState('');
  const [lr, setLr] = useState('');
  const [freight, setFreight] = useState('0');
  const convert = useMutation({
    mutationFn: () => convertChallan(challan.id ?? '', { invoice_date: date, transport_name: transport || null, lr_no: lr || null, freight: toNumber(freight) }),
    onSuccess: async (invId) => { await qc.invalidateQueries({ queryKey: ['challans'] }); await qc.invalidateQueries({ queryKey: ['invoices'] }); toast({ title: 'Invoice confirmed against the challan' }); navigate(`/invoices/${invId}`); },
    onError: (err) => toastError(err, 'Could not convert'),
  });
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogHeader><DialogTitle>Bill challan {challan.challan_no}</DialogTitle><DialogDescription>Rates come from the customer's price list on the invoice date. The invoice is confirmed at once because the goods already left.</DialogDescription></DialogHeader>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Invoice date" htmlFor="cc-date" className="col-span-2"><Input id="cc-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
          <Field label="Transport" htmlFor="cc-tr"><Input id="cc-tr" value={transport} onChange={(e) => setTransport(e.target.value)} /></Field>
          <Field label="L.R. no." htmlFor="cc-lr"><Input id="cc-lr" value={lr} onChange={(e) => setLr(e.target.value)} /></Field>
          <Field label="Freight (₹)" htmlFor="cc-fr"><Input id="cc-fr" type="number" step="0.01" className="num" value={freight} onChange={(e) => setFreight(e.target.value)} /></Field>
        </div>
        <DialogFooter><Button variant="outline" onClick={onClose}>Back</Button><Button onClick={() => convert.mutate()} disabled={convert.isPending}>{convert.isPending ? 'Billing…' : 'Create invoice'}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ------------------------------------------------------------------ print
/** Delivery challan on the shared sheet: quantities only, no money. */
export function ChallanPrintPage() {
  const { id } = useParams();
  const me = useMe();
  const challan = useQuery({ queryKey: ['challans', 'one', id], queryFn: () => getChallan(id ?? ''), enabled: Boolean(id) });
  const lines = useQuery({ queryKey: ['challans', 'lines', id], queryFn: () => getChallanLines(id ?? ''), enabled: Boolean(id) });
  const customer = useQuery({ queryKey: ['customers', 'one', challan.data?.customer_id], queryFn: () => getCustomer(challan.data?.customer_id ?? ''), enabled: Boolean(challan.data?.customer_id) });
  const template = useQuery({ queryKey: ['setup', 'print_templates', 'challan'], queryFn: () => getPrintTemplate('challan') });
  useEffect(() => { document.title = challan.data ? `Challan ${challan.data.challan_no}` : 'Challan'; }, [challan.data]);
  if (challan.isLoading || lines.isLoading || me.isLoading || template.isLoading) return <Spinner label="Preparing print…" full />;
  if (!challan.data || !lines.data) return <p className="p-6 text-sm text-destructive">Challan not found.</p>;
  const c = challan.data;
  const phones = [customer.data?.mobile1, customer.data?.mobile2, customer.data?.mobile3].filter(Boolean).join(',');
  return (
    <SalesDocPrint
      title="DELIVERY CHALLAN"
      org={me.data}
      template={template.data}
      party={{ name: c.customer_name ?? '', town: c.customer_town ?? '', phones }}
      meta={[
        { label: 'Date', value: dateDMY(c.challan_date), bold: true },
        { label: 'Challan No.', value: c.challan_no ?? '', bold: true },
        { label: 'From', value: c.location_name ?? '' },
        { label: 'Vehicle', value: c.vehicle_number ?? '', transport: true },
        { label: 'Notes', value: c.notes ?? '' },
      ]}
      lines={lines.data.map((l, i) => ({ key: String(l.id ?? i), code: l.item_code ?? '', name: l.item_name ?? '', units_per_box: toNumber(l.units_per_box), boxes: toNumber(l.boxes), qty: toNumber(l.boxes) * toNumber(l.units_per_box), rate: 0, amount: 0 }))}
      totals={null}
      backTo={`/challans/${c.id}`}
      backLabel="Back to challan"
    />
  );
}
