import { z } from 'zod';

export const invoiceHeaderSchema = z.object({
  customer_id: z.string().min(1, 'Choose a customer'),
  invoice_date: z.string().min(1, 'Date is required'),
  location_id: z.string().min(1, 'Choose where the stock leaves from'),
  vehicle_id: z.string(),
  transport_name: z.string().trim().max(80),
  lr_no: z.string().trim().max(40),
  lr_date: z.string(),
  freight: z.coerce.number().min(0),
  discount: z.coerce.number().min(0),
  round_off: z.coerce.number(),
  notes: z.string().trim().max(500),
});

export type InvoiceHeaderForm = z.infer<typeof invoiceHeaderSchema>;

/** A line as the operator builds it: CODE, Boxes, Rate typed; the rest read from the master. */
export interface DraftLine {
  key: string;
  item_id: string;
  item_code: string;
  item_name: string;
  units_per_box: number;
  boxes: number;
  rate: number;
}
