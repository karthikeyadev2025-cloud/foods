import { z } from 'zod';

export const vehicleSchema = z.object({
  vehicle_number: z.string().trim().min(1, 'Vehicle number is required').max(20),
  owner_name: z.string().trim().max(120),
  driver_id: z.string(),
  route_id: z.string(),
  capacity_boxes: z.coerce.number().int().min(0),
  is_active: z.boolean(),
});

export type VehicleInput = z.infer<typeof vehicleSchema>;

export const VEHICLE_DEFAULTS: VehicleInput = {
  vehicle_number: '',
  owner_name: '',
  driver_id: '',
  route_id: '',
  capacity_boxes: 0,
  is_active: true,
};
