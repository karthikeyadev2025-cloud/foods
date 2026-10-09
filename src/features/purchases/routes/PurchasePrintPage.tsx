import { useQuery } from '@tanstack/react-query';
import { useEffect } from 'react';
import { useParams } from 'react-router-dom';
import { SalesDocPrint } from '@/components/print/SalesDocPrint';
import type { PrintTemplateLike } from '@/components/print/template';
import { Spinner } from '@/components/Spinner';
import { useMe } from '@/features/auth/hooks';
import { getPrintTemplate } from '@/features/setup/api';
import { dateDMY, toNumber } from '@/lib/format';
import { supabase } from '@/lib/supabase';
import { getPurchase, getPurchaseLines } from '../api';

/**
 * A purchase on paper — the goods-inward sheet that goes in the file with the
 * supplier's own bill, and the one the godown checks the delivery against.
 *
 * It is the same sheet as an invoice, because the shop should only ever have to
 * learn one. What differs is what a purchase is NOT: it is not sold to anybody.
 * So the sales terms, the "thanking you for shopping" line and the transport
 * block are off unless the owner turns them on in the designer, and the party
 * block names the supplier the goods came FROM.
 */
const PURCHASE_DEFAULTS: PrintTemplateLike = {
  paper: 'A4',
  show_fields: { terms: false, thanks: false, transport: false, phones: true },
  terms: [],
  header_html: null,
  footer_html: null,
};

export function PurchasePrintPage() {
  const { id } = useParams();
  const me = useMe();
  const purchase = useQuery({ queryKey: ['purchases', 'one', id], queryFn: () => getPurchase(id ?? ''), enabled: Boolean(id) });
  const lines = useQuery({ queryKey: ['purchases', 'lines', id], queryFn: () => getPurchaseLines(id ?? ''), enabled: Boolean(id) });
  const template = useQuery({ queryKey: ['setup', 'print_templates', 'purchase'], queryFn: () => getPrintTemplate('purchase') });
  const supplierId = purchase.data?.supplier_id;
  const supplier = useQuery({
    queryKey: ['suppliers', 'one', supplierId],
    queryFn: async () => {
      if (!supplierId) return null;
      const { data } = await supabase.from('suppliers').select('*').eq('id', supplierId).maybeSingle();
      return data;
    },
    enabled: Boolean(supplierId),
  });
  const supplierName = purchase.data?.supplier_name ?? supplier.data?.name;
  const customer = useQuery({
    queryKey: ['customers', 'match', supplierName],
    queryFn: async () => {
      if (!supplierName) return null;
      const { data } = await supabase.from('customers').select('*').eq('name', supplierName).maybeSingle();
      return data;
    },
    enabled: Boolean(supplierName),
  });

  useEffect(() => {
    document.title = purchase.data ? `Purchase ${purchase.data.bill_no}` : 'Purchase';
  }, [purchase.data]);

  if (purchase.isLoading || lines.isLoading || me.isLoading || template.isLoading) return <Spinner label="Preparing print…" full />;
  if (!purchase.data || !lines.data) return <p className="p-6 text-sm text-destructive">Purchase not found.</p>;

  const p = purchase.data;
  const sup = supplier.data;
  const cust = customer.data;

  const phoneList = [
    p.supplier_mobile,
    sup?.mobile1,
    cust?.mobile1,
    cust?.mobile2,
  ].filter(Boolean) as string[];
  const phones = [...new Set(phoneList)].join(', ');

  const town = p.supplier_town || sup?.town || cust?.town || '';
  const address = p.supplier_address || (sup as { address?: string | null } | null)?.address || cust?.address || '';

  return (
    <SalesDocPrint
      title="PURCHASE BILL"
      org={me.data}
      template={template.data ?? PURCHASE_DEFAULTS}
      party={{ name: p.supplier_name ?? 'CASH PURCHASE', town, address, phones }}
      meta={[
        { label: 'Bill Date', value: dateDMY(p.bill_date), bold: true },
        { label: 'Bill No.', value: p.bill_no ?? '', bold: true },
        { label: 'Into Godown', value: p.location_name ?? '' },
      ]}
      lines={lines.data.map((l) => ({
        key: String(l.id),
        code: l.item_code ?? '',
        name: l.item_name ?? '',
        units_per_box: toNumber(l.units_per_box),
        boxes: toNumber(l.boxes),
        qty: toNumber(l.qty),
        rate: toNumber(l.rate),
        amount: toNumber(l.amount),
      }))}
      // Other charges print on the same line freight does on a bill — it is the
      // same thing from the other side of the counter: what the delivery cost
      // on top of the goods.
      totals={{ discount: 0, freight: toNumber(p.other_charges), round_off: 0, total: toNumber(p.total) }}
      backTo={`/purchases/${p.id}`}
      backLabel="Back to purchase"
    />
  );
}
