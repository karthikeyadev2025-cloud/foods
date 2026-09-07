import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Pencil, Plus } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { listStaff, routesApi } from '@/features/setup/api';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { int } from '@/lib/format';
import { createVehicle, listVehicles, updateVehicle, type VehicleRow } from '../api';
import { VEHICLE_DEFAULTS, vehicleSchema, type VehicleInput } from '../schema';
import { VehicleTabs } from './TripsPage';

const KEY = ['vehicles', 'list'] as const;

export function VehiclesPage() {
  const perms = usePermissions();
  const vehicles = useQuery({ queryKey: KEY, queryFn: listVehicles });
  const [editing, setEditing] = useState<{ mode: 'new' } | { mode: 'edit'; row: VehicleRow } | null>(null);
  const canEdit = perms.canEdit('vehicles');

  const onExport = () =>
    exportToExcel(
      'vehicles',
      (vehicles.data ?? []).map((v) => ({
        'Vehicle no.': v.vehicle_number,
        Owner: v.owner_name,
        Driver: v.driver_name,
        Route: v.route_name,
        'Capacity (boxes)': v.capacity_boxes,
        'Stock location': v.location_name,
        Active: v.is_active,
      })),
      'Vehicles',
    );

  return (
    <div className="space-y-3">
      <PageHeader
        title="Vehicles"
        description="Each van is a stock location: loading it is a real stock transfer, and its stock shows on the closing stock report."
        actions={
          <>
            <Button variant="outline" size="sm" onClick={onExport} disabled={!vehicles.data?.length}>
              <Download /> Excel
            </Button>
            {canEdit && (
              <Button size="sm" onClick={() => setEditing({ mode: 'new' })}>
                <Plus /> New vehicle
              </Button>
            )}
          </>
        }
      />

      <VehicleTabs active="vehicles" />
      {vehicles.isLoading ? (
        <Spinner />
      ) : vehicles.error ? (
        <p role="alert" className="text-sm text-destructive">
          Could not load vehicles: {vehicles.error.message}
        </p>
      ) : !vehicles.data?.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No vehicles yet.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Vehicle no.</TableHead>
                <TableHead>Owner</TableHead>
                <TableHead>Driver</TableHead>
                <TableHead>Route</TableHead>
                <TableHead className="text-right">Capacity (boxes)</TableHead>
                <TableHead>Stock location</TableHead>
                {canEdit && <TableHead className="w-16 text-right">Edit</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {vehicles.data.map((v) => (
                <TableRow key={v.id}>
                  <TableCell className="font-medium">
                    {v.vehicle_number}
                    {!v.is_active && (
                      <Badge variant="outline" className="ml-1">
                        inactive
                      </Badge>
                    )}
                  </TableCell>
                  <TableCell>{v.owner_name ?? '—'}</TableCell>
                  <TableCell>{v.driver_name ?? '—'}</TableCell>
                  <TableCell>{v.route_name ?? '—'}</TableCell>
                  <TableCell className="num">{v.capacity_boxes === null ? '—' : int(v.capacity_boxes)}</TableCell>
                  <TableCell className="text-muted-foreground">{v.location_name ?? '—'}</TableCell>
                  {canEdit && (
                    <TableCell className="text-right">
                      <Button variant="ghost" size="icon" aria-label={`Edit ${v.vehicle_number}`} onClick={() => setEditing({ mode: 'edit', row: v })}>
                        <Pencil />
                      </Button>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {editing && (
        <VehicleDialog
          key={editing.mode === 'edit' ? editing.row.id : 'new'}
          vehicle={editing.mode === 'edit' ? editing.row : undefined}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function VehicleDialog({ vehicle, onClose }: { vehicle?: VehicleRow; onClose: () => void }) {
  const queryClient = useQueryClient();
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const routes = useQuery({ queryKey: ['setup', 'routes'], queryFn: routesApi.list });
  const drivers = (staff.data ?? []).filter((s) => s.is_active && (s.role === 'driver' || s.id === vehicle?.driver_id));
  const form = useForm<VehicleInput>({
    resolver: zodResolver(vehicleSchema),
    defaultValues: vehicle
      ? {
          vehicle_number: vehicle.vehicle_number ?? '',
          owner_name: vehicle.owner_name ?? '',
          driver_id: vehicle.driver_id ?? '',
          route_id: vehicle.route_id ?? '',
          capacity_boxes: vehicle.capacity_boxes ?? 0,
          is_active: vehicle.is_active ?? true,
        }
      : VEHICLE_DEFAULTS,
  });
  const e = form.formState.errors;

  const save = useMutation({
    mutationFn: (v: VehicleInput) => {
      const values = {
        vehicle_number: v.vehicle_number.toUpperCase(),
        owner_name: v.owner_name || null,
        driver_id: v.driver_id || null,
        route_id: v.route_id || null,
        capacity_boxes: v.capacity_boxes || null,
        is_active: v.is_active,
      };
      return vehicle?.id ? updateVehicle(vehicle.id, values) : createVehicle(values);
    },
    onSuccess: async (saved) => {
      await queryClient.invalidateQueries({ queryKey: ['vehicles'] });
      await queryClient.invalidateQueries({ queryKey: ['setup', 'stock_locations'] });
      toast({ title: `${saved.vehicle_number} saved`, description: vehicle ? undefined : 'Its stock location was created.' });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not save the vehicle'),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{vehicle ? 'Edit vehicle' : 'New vehicle'}</DialogTitle>
          <DialogDescription>A matching stock location is created automatically.</DialogDescription>
        </DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3" noValidate>
          <Field label="Vehicle number" htmlFor="vh-no" error={e.vehicle_number?.message}>
            <Input id="vh-no" autoFocus className="uppercase" placeholder="AP07 AB 1234" {...form.register('vehicle_number')} />
          </Field>
          <Field label="Owner name" htmlFor="vh-owner" error={e.owner_name?.message}>
            <Input id="vh-owner" {...form.register('owner_name')} />
          </Field>
          <Field label="Driver" htmlFor="vh-driver" error={e.driver_id?.message} help={drivers.length ? undefined : 'Add staff with the Driver role under Setup → Users.'}>
            <NativeSelect id="vh-driver" {...form.register('driver_id')}>
              <option value="">— none —</option>
              {drivers.map((d) => (
                <option key={d.id} value={d.id}>
                  {d.full_name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Route plan" htmlFor="vh-route" error={e.route_id?.message}>
            <NativeSelect id="vh-route" {...form.register('route_id')}>
              <option value="">— none —</option>
              {(routes.data ?? []).filter((r) => r.is_active).map((r) => (
                <option key={r.id} value={r.id}>
                  {r.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Capacity (boxes)" htmlFor="vh-cap" error={e.capacity_boxes?.message}>
            <Input id="vh-cap" type="number" inputMode="numeric" className="num" {...form.register('capacity_boxes')} />
          </Field>
          <label htmlFor="vh-active" className="flex items-center gap-2 pt-5 text-sm">
            <Checkbox id="vh-active" {...form.register('is_active')} />
            Active
          </label>
          <DialogFooter className="col-span-2 pt-2">
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
