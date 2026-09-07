import { useQuery } from '@tanstack/react-query';
import { useEffect } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { useMe } from '@/features/auth/hooks';
import { getCustomer } from '@/features/customers/api';
import { amount, dateDMY, int, qty } from '@/lib/format';
import { amountInWords } from '@/lib/money';
import { getInvoice, getInvoiceLines } from '../api';

/**
 * A4 print, matching the client's quotation form line for line. The numbered
 * terms come from the org's trade terms — never from this template.
 */
export function InvoicePrintPage() {
  const { id } = useParams();
  const me = useMe();
  const invoice = useQuery({ queryKey: ['invoices', 'one', id], queryFn: () => getInvoice(id ?? ''), enabled: Boolean(id) });
  const lines = useQuery({ queryKey: ['invoices', 'lines', id], queryFn: () => getInvoiceLines(id ?? ''), enabled: Boolean(id) });
  const customer = useQuery({
    queryKey: ['customers', 'one', invoice.data?.customer_id],
    queryFn: () => getCustomer(invoice.data?.customer_id ?? ''),
    enabled: Boolean(invoice.data?.customer_id),
  });

  useEffect(() => {
    document.title = invoice.data ? `Invoice ${invoice.data.invoice_no}` : 'Invoice';
  }, [invoice.data]);

  if (invoice.isLoading || lines.isLoading || me.isLoading) return <Spinner label="Preparing print…" full />;
  if (!invoice.data || !lines.data) return <p className="p-6 text-sm text-destructive">Invoice not found.</p>;

  const inv = invoice.data;
  const org = me.data;
  const totalBoxes = lines.data.reduce((s, l) => s + Number(l.boxes ?? 0), 0);
  const totalQty = lines.data.reduce((s, l) => s + Number(l.qty ?? 0), 0);
  const phones = [customer.data?.mobile1, customer.data?.mobile2, customer.data?.mobile3].filter(Boolean).join(',');

  return (
    <div className="min-h-screen bg-neutral-200 print:bg-white">
      <div className="no-print flex items-center justify-between gap-2 border-b bg-card px-4 py-2 text-sm">
        <Button asChild variant="ghost" size="sm">
          <Link to={`/invoices/${inv.id}`}>← Back to invoice</Link>
        </Button>
        <Button size="sm" onClick={() => window.print()}>
          Print
        </Button>
      </div>

      <div className="print-sheet mx-auto my-4 bg-white p-8 text-[12px] leading-tight text-black print:my-0 print:p-6">
        <div className="text-center text-base font-bold tracking-wide">
          {inv.status === 'draft' ? 'PROFORMA' : 'INVOICE'}
        </div>
        <div className="text-center text-xs text-neutral-700">{org?.org_name ?? 'JYOTHI FOODS'}{org?.address ? ` · ${org.address}` : ''}{org?.org_phone ? ` · Ph ${org.org_phone}` : ''}{org?.fssai_no ? ` · FSSAI ${org.fssai_no}` : ''}</div>

        <div className="mt-2 grid grid-cols-2 border border-black">
          <div className="border-r border-black p-2">
            <div className="font-bold">{inv.customer_name}</div>
            <div>{inv.customer_town}</div>
            {phones && <div>PH NO : {phones}</div>}
          </div>
          <div className="p-2">
            <div className="flex justify-between"><span className="font-bold">Invoice Date</span><span>{dateDMY(inv.invoice_date)}</span></div>
            <div className="flex justify-between"><span className="font-bold">Invoice No.</span><span>{inv.invoice_no}</span></div>
            <div className="flex justify-between"><span>Transport Name</span><span>{inv.transport_name ?? ''}</span></div>
            <div className="flex justify-between"><span>L.R No.</span><span>{inv.lr_no ?? ''}</span></div>
            <div className="flex justify-between"><span>L.R Date</span><span>{inv.lr_date ? dateDMY(inv.lr_date) : ''}</span></div>
            <div className="flex justify-between"><span>Freight</span><span>{Number(inv.freight ?? 0) ? amount(inv.freight) : ''}</span></div>
          </div>
        </div>

        <table className="mt-2 w-full border-collapse border border-black">
          <thead>
            <tr className="border-b border-black">
              <th className="w-10 border-r border-black p-1 text-left">S.No</th>
              <th className="w-16 border-r border-black p-1 text-left">CODE</th>
              <th className="border-r border-black p-1 text-left">Item Name</th>
              <th className="w-16 border-r border-black p-1 text-right">Jars</th>
              <th className="w-16 border-r border-black p-1 text-right">Boxes</th>
              <th className="w-16 border-r border-black p-1 text-right">Qty</th>
              <th className="w-16 border-r border-black p-1 text-right">Rate</th>
              <th className="w-24 p-1 text-right">Total</th>
            </tr>
          </thead>
          <tbody>
            {lines.data.map((l, i) => (
              <tr key={l.id}>
                <td className="border-r border-black px-1 text-center">{i + 1}</td>
                <td className="border-r border-black px-1">{l.item_code}</td>
                <td className="border-r border-black px-1">{l.item_name}</td>
                <td className="border-r border-black px-1 text-right tabular-nums">{qty(l.units_per_box)}</td>
                <td className="border-r border-black px-1 text-right tabular-nums">{qty(l.boxes)}</td>
                <td className="border-r border-black px-1 text-right tabular-nums">{qty(l.qty)}</td>
                <td className="border-r border-black px-1 text-right tabular-nums">{amount(l.rate)}</td>
                <td className="px-1 text-right tabular-nums">{amount(l.amount)}</td>
              </tr>
            ))}
            {Array.from({ length: Math.max(0, 18 - lines.data.length) }).map((_, i) => (
              <tr key={`pad-${i}`} className="h-4">
                <td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" />
                <td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" />
                <td className="border-r border-black" /><td />
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t border-black font-bold">
              <td colSpan={4} className="border-r border-black px-1 text-right">Total:</td>
              <td className="border-r border-black px-1 text-right tabular-nums">{qty(totalBoxes)}</td>
              <td className="border-r border-black px-1 text-right tabular-nums">{int(totalQty)}</td>
              <td className="border-r border-black" />
              <td />
            </tr>
          </tfoot>
        </table>

        <div className="mt-1 grid grid-cols-[1fr_auto] border border-black">
          <div className="border-r border-black p-1">
            <div className="font-bold">Total amount in words :</div>
            <div>{amountInWords(Number(inv.total ?? 0))}</div>
          </div>
          <div className="p-1 text-right">
            {Number(inv.discount ?? 0) > 0 && <div>Discount : {amount(inv.discount)}</div>}
            {Number(inv.freight ?? 0) > 0 && <div>Freight : {amount(inv.freight)}</div>}
            {Number(inv.round_off ?? 0) !== 0 && <div>Round off : {amount(inv.round_off)}</div>}
            <div className="text-sm font-bold">Net Amount : <span className="ml-4 tabular-nums">{amount(inv.total)}</span></div>
          </div>
        </div>

        <div className="mt-1 flex justify-between border border-black p-1">
          <span className="font-bold">E&amp;E.O</span>
          <span>For {org?.org_name ?? 'JYOTHI FOODS'}</span>
        </div>

        <ol className="mt-2 list-decimal space-y-0.5 pl-5">
          <li className="font-bold uppercase">Damage or breakage only {int(org?.breakage_recovery_pct ?? 0)}% recovery.</li>
          <li>Interest at {int(org?.interest_pct_pa ?? 0)}% will be charged from the date of the bill if not paid within {int(org?.credit_days ?? 0)} days.</li>
          <li>Subject to {org?.jurisdiction ?? ''} jurisdiction only.</li>
        </ol>

        <div className="mt-8 flex items-end justify-between">
          <div className="text-center font-bold">THANKING YOU FOR SHOPPING &amp; VISIT AGAIN</div>
          <div>Authorised Signatory.</div>
        </div>
      </div>

      <style>{`
        .print-sheet { width: 210mm; min-height: 297mm; }
        @page { size: A4; margin: 10mm; }
        @media print {
          .print-sheet { width: auto; min-height: 0; box-shadow: none; }
          body { background: white; }
        }
      `}</style>
    </div>
  );
}
