import { z } from 'zod';

export const purchaseHeaderSchema = z.object({
  supplier_id: z.string(),
  bill_no: z.string().trim().max(40),
  bill_date: z.string().min(1, 'Date is required'),
  location_id: z.string().min(1, 'Choose the godown the goods came into'),
  other_charges: z.coerce.number().min(0),
  paid_amount: z.coerce.number().min(0),
  notes: z.string().trim().max(500),
});
export type PurchaseHeaderForm = z.infer<typeof purchaseHeaderSchema>;

export interface PurchaseDraftLine {
  key: string;
  item_id: string;
  item_code: string;
  item_name: string;
  uom_id: string;
  qty: number;
  rate: number;
}

export const supplierSchema = z.object({
  name: z.string().trim().min(1, 'Name is required').max(120),
  mobile1: z.string().trim().max(20),
  town: z.string().trim().max(80),
  opening_balance: z.coerce.number(),
  is_active: z.boolean(),
});
export type SupplierInput = z.infer<typeof supplierSchema>;
