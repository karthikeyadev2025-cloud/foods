import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Plus } from 'lucide-react';
import { useState } from 'react';
import { Link, NavLink, useNavigate } from 'react-router-dom';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { listStaff, routesApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { amount, dateDMY, qty, toISODate, toNumber } from '@/lib/format';
import { cn } from '@/lib/utils';
import { listVehicles } from '../api';
import { TRIP_STATUSES, createTrip, listTrips, tripTone, type TripStatus } from '../trips-api';

export function VehicleTabs({ active }: { active: 'vehicles' | 'trips' }) {
  return (
    <nav className="flex gap-1 border-b" aria-label="Vehicle sections">
      {[{ to: '/vehicles', label: 'Vehicles', key: 'vehicles' }, { to: '/vehicles/trips', label: 'Trips', key: 'trips' }].map((t) => (
        <NavLink key={t.key} to={t.to} end className={() => cn('-mb-px border-b-2 px-3 py-1.5 text-sm', active === t.key ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}>
          {t.label}
        </NavLink>
      ))}
    </nav>
  );
}

export function TripsPage() {
  const perms = usePermissions();
  const navigate = useNavigate();
  const [status, setStatus] = useState<TripStatus | ''>('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [creating, setCreating] = useState(false);
  const trips = useQuery({ queryKey: ['trips', 'list', status, from, to], queryFn: () => listTrips({ status, from, to }) });

  return (
    <div className="space-y-3">
      <PageHeader title="Trips" description="Load the van (stock moves godown → van), sell on the road, settle at day end: loaded vs sold vs returned vs collected."
        actions={perms.canEdit('vehicles') && <Button size="sm" onClick={() => setCreating(true)}><Plus /> New trip</Button>} />
      <VehicleTabs active="trips" />
      <div className="flex flex-wrap items-center gap-2">
        <NativeSelect aria-label="Status" className="h-8 w-40" value={status} onChange={(e) => setStatus(e.target.value as TripStatus | '')}>
          <option value="">All statuses</option>
          {TRIP_STATUSES.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
        </NativeSelect>
        <Input type="date" aria-label="From date" className="h-8 w-40" value={from} onChange={(e) => setFrom(e.target.value)} />
        <Input type="date" aria-label="To date" className="h-8 w-40" value={to} onChange={(e) => setTo(e.target.value)} />
      </div>
      {trips.isLoading ? <Spinner /> : trips.error ? (
        <p role="alert" className="text-sm text-destructive">Could not load trips: {trips.error.message}</p>
      ) : !trips.data?.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No trips yet.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Date</TableHead><TableHead>Vehicle</TableHead><TableHead>Driver</TableHead><TableHead>Route</TableHead><TableHead>Status</TableHead><TableHead className="text-right">Loaded (boxes)</TableHead><TableHead className="text-right">Sold</TableHead><TableHead className="text-right">Collected</TableHead></TableRow></TableHeader>
            <TableBody>
              {trips.data.map((t) => (
                <TableRow key={t.id ?? ''} className="cursor-pointer" tabIndex={0} onClick={() => navigate(`/vehicles/trips/${t.id}`)} onKeyDown={(e) => e.key === 'Enter' && navigate(`/vehicles/trips/${t.id}`)}>
                  <TableCell>{dateDMY(t.trip_date)}</TableCell><TableCell className="font-medium">{t.vehicle_number}</TableCell><TableCell>{t.driver_name ?? '—'}</TableCell><TableCell className="text-muted-foreground">{t.route_name ?? '—'}</TableCell>
                  <TableCell><Badge variant={tripTone[(t.status ?? 'planned') as TripStatus]}>{TRIP_STATUSES.find((s) => s.value === t.status)?.label}</Badge></TableCell>
                  <TableCell className="num">{qty(t.loaded_boxes)}</TableCell><TableCell className="num">{amount(t.sold_value)}</TableCell><TableCell className="num">{amount(t.collected)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {creating && <NewTripDialog onClose={() => setCreating(false)} />}
    </div>
  );
}

function NewTripDialog({ onClose }: { onClose: () => void }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const vehicles = useQuery({ queryKey: ['vehicles', 'list'], queryFn: listVehicles });
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list });
  const [vehicleId, setVehicleId] = useState('');
  const [driverId, setDriverId] = useState('');
  const [routeId, setRouteId] = useState('');
  const [date, setDate] = useState(toISODate());
  const [km, setKm] = useState('');
  const vehicle = vehicles.data?.find((v) => v.id === vehicleId);

  const create = useMutation({
    mutationFn: () => {
      if (!vehicleId) throw new Error('Choose a vehicle');
      return createTrip({ vehicle_id: vehicleId, driver_id: driverId || vehicle?.driver_id || null, route_id: routeId || vehicle?.route_id || null, trip_date: date, opening_km: km ? toNumber(km) : null });
    },
    onSuccess: async (id) => {
      await queryClient.invalidateQueries({ queryKey: ['trips'] });
      toast({ title: 'Trip created — load the van next' });
      onClose();
      navigate(`/vehicles/trips/${id}`);
    },
    onError: (err) => toastError(err, 'Could not create the trip'),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader><DialogTitle>New trip</DialogTitle></DialogHeader>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Vehicle" htmlFor="tr-veh" className="col-span-2">
            <NativeSelect id="tr-veh" autoFocus value={vehicleId} onChange={(e) => setVehicleId(e.target.value)}>
              <option value="">— choose —</option>
              {(vehicles.data ?? []).filter((v) => v.is_active).map((v) => <option key={v.id} value={v.id ?? ''}>{v.vehicle_number}{v.driver_name ? ` — ${v.driver_name}` : ''}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Driver" htmlFor="tr-driver" help={vehicle?.driver_name ? `Vehicle default: ${vehicle.driver_name}` : undefined}>
            <NativeSelect id="tr-driver" value={driverId} onChange={(e) => setDriverId(e.target.value)}>
              <option value="">— vehicle default —</option>
              {(staff.data ?? []).filter((s) => s.is_active && s.role === 'driver').map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Route" htmlFor="tr-route" help={vehicle?.route_name ? `Vehicle default: ${vehicle.route_name}` : undefined}>
            <NativeSelect id="tr-route" value={routeId} onChange={(e) => setRouteId(e.target.value)}>
              <option value="">— vehicle default —</option>
              {(routes.data ?? []).filter((r) => r.is_active).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
            </NativeSelect>
          </Field>
          <Field label="Trip date" htmlFor="tr-date"><Input id="tr-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
          <Field label="Opening km" htmlFor="tr-km"><Input id="tr-km" type="number" step="0.1" className="num" value={km} onChange={(e) => setKm(e.target.value)} /></Field>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={() => create.mutate()} disabled={create.isPending}>{create.isPending ? 'Creating…' : 'Create trip'}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function TripsLink() {
  return <Button asChild variant="ghost" size="sm"><Link to="/vehicles/trips">← Trips</Link></Button>;
}
