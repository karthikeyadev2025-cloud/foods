import { useQuery } from '@tanstack/react-query';
import { useEffect } from 'react';
import { useParams } from 'react-router-dom';
import { SalesDocPrint } from '@/components/print/SalesDocPrint';
import { Spinner } from '@/components/Spinner';
import { useMe } from '@/features/auth/hooks';
import { getCustomer } from '@/features/customers/api';
import { getPrintTemplate } from '@/features/setup/api';
import { amount, dateDMY, toNumber } from '@/lib/format';
import { getInvoice, getInvoiceLines } from '../api';

/**
 * Invoice print, on the shared sheet. Paper, columns and blocks come from the org's
 * invoice print template; the numbered terms from the business profile unless the
 * owner has written their own in the designer.
 */
export function InvoicePrintPage() {
  const { id } = useParams();
  const me = useMe();
  const invoice = useQuery({ queryKey: ['invoices', 'one', id], queryFn: () => getInvoice(id ?? ''), enabled: Boolean(id) });
  const lines = useQuery({ queryKey: ['invoices', 'lines', id], queryFn: () => getInvoiceLines(id ?? ''), enabled: Boolean(id) });
  const template = useQuery({ queryKey: ['setup', 'print_templates', 'invoice'], queryFn: () => getPrintTemplate('invoice') });
  const customer = useQuery({
    queryKey: ['customers', 'one', invoice.data?.customer_id],
    queryFn: () => getCustomer(invoice.data?.customer_id ?? ''),
    enabled: Boolean(invoice.data?.customer_id),
  });

  useEffect(() => {
    document.title = invoice.data ? `Invoice ${invoice.data.invoice_no}` : 'Invoice';
  }, [invoice.data]);

  if (invoice.isLoading || lines.isLoading || me.isLoading || template.isLoading) return <Spinner label="Preparing print…" full />;
  if (!invoice.data || !lines.data) return <p className="p-6 text-sm text-destructive">Invoice not found.</p>;

  const inv = invoice.data;
  const phones = [customer.data?.mobile1, customer.data?.mobile2, customer.data?.mobile3].filter(Boolean).join(',');

  return (
    <SalesDocPrint
      title={inv.status === 'draft' ? 'PROFORMA' : 'INVOICE'}
      org={me.data}
      template={template.data}
      party={{ name: inv.customer_name ?? '', town: inv.customer_town ?? '', phones }}
      meta={[
        { label: 'Invoice Date', value: dateDMY(inv.invoice_date), bold: true },
        { label: 'Invoice No.', value: inv.invoice_no ?? '', bold: true },
        { label: 'Transport Name', value: inv.transport_name ?? '', transport: true },
        { label: 'L.R No.', value: inv.lr_no ?? '', transport: true },
        { label: 'L.R Date', value: inv.lr_date ? dateDMY(inv.lr_date) : '', transport: true },
        { label: 'Freight', value: toNumber(inv.freight) ? amount(inv.freight) : '', transport: true },
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
      totals={{ discount: toNumber(inv.discount), freight: toNumber(inv.freight), round_off: toNumber(inv.round_off), total: toNumber(inv.total) }}
      backTo={`/invoices/${inv.id}`}
      backLabel="Back to invoice"
    />
  );
}
