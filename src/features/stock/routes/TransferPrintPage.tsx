import { useQuery } from '@tanstack/react-query';
import { useEffect } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { useMe } from '@/features/auth/hooks';
import { dateDMY, int, qty, toNumber } from '@/lib/format';
import { getTransferLines, listTransfers } from '../inventory-api';

/** T9.3 — the transfer note that travels with the goods. */
export function TransferPrintPage() {
  const { id = '' } = useParams();
  const me = useMe();
  const transfers = useQuery({ queryKey: ['stock', 'transfers'], queryFn: listTransfers });
  const lines = useQuery({ queryKey: ['stock', 'transfer-lines', id], queryFn: () => getTransferLines(id) });
  const t = transfers.data?.find((x) => x.id === id);
  useEffect(() => { document.title = t ? `Transfer ${t.transfer_no}` : 'Transfer note'; }, [t]);
  if (transfers.isLoading || lines.isLoading) return <Spinner label="Preparing…" full />;
  if (!t || !lines.data) return <p className="p-6 text-sm text-destructive">Transfer not found.</p>;
  return (
    <div className="min-h-screen bg-neutral-200 print:bg-white">
      <div className="no-print flex items-center justify-between gap-2 border-b bg-card px-4 py-2 text-sm">
        <Button asChild variant="ghost" size="sm"><Link to="/stock/transfers">← Transfers</Link></Button>
        <Button size="sm" onClick={() => window.print()}>Print</Button>
      </div>
      <div className="print-sheet mx-auto my-4 bg-white p-8 text-[12px] leading-tight text-black print:my-0 print:p-6">
        <div className="text-center text-base font-bold tracking-wide">STOCK TRANSFER NOTE</div>
        <div className="text-center text-xs text-neutral-700">{me.data?.org_name ?? 'JYOTHI FOODS'}{me.data?.address ? ` · ${me.data.address}` : ''}</div>
        <div className="mt-2 grid grid-cols-2 border border-black">
          <div className="border-r border-black p-2"><div><span className="font-bold">From:</span> {t.from_name}</div><div><span className="font-bold">To:</span> {t.to_name}</div>{t.notes && <div>{t.notes}</div>}</div>
          <div className="p-2"><div className="flex justify-between"><span className="font-bold">Transfer No.</span><span>{t.transfer_no}</span></div><div className="flex justify-between"><span className="font-bold">Date</span><span>{dateDMY(t.txn_date)}</span></div><div className="flex justify-between"><span>Prepared by</span><span>{t.created_by_name ?? ''}</span></div></div>
        </div>
        <table className="mt-2 w-full border-collapse border border-black">
          <thead><tr className="border-b border-black"><th className="w-10 border-r border-black p-1 text-left">S.No</th><th className="w-16 border-r border-black p-1 text-left">CODE</th><th className="border-r border-black p-1 text-left">Item Name</th><th className="w-14 border-r border-black p-1 text-left">Pack</th><th className="w-16 border-r border-black p-1 text-right">Jars</th><th className="w-16 border-r border-black p-1 text-right">Boxes</th><th className="w-16 p-1 text-right">Units</th></tr></thead>
          <tbody>{lines.data.map((l, i) => <tr key={l.id ?? i}><td className="border-r border-black px-1 text-center">{i + 1}</td><td className="border-r border-black px-1">{l.item_code}</td><td className="border-r border-black px-1">{l.item_name}</td><td className="border-r border-black px-1">{l.pack_code}</td><td className="border-r border-black px-1 text-right tabular-nums">{int(l.units_per_box)}</td><td className="border-r border-black px-1 text-right tabular-nums">{qty(l.boxes)}</td><td className="px-1 text-right tabular-nums">{qty(l.qty_base)}</td></tr>)}</tbody>
          <tfoot><tr className="border-t border-black font-bold"><td colSpan={5} className="border-r border-black px-1 text-right">Total</td><td className="border-r border-black px-1 text-right tabular-nums">{qty(lines.data.reduce((s, l) => s + toNumber(l.boxes), 0))}</td><td className="px-1 text-right tabular-nums">{qty(lines.data.reduce((s, l) => s + toNumber(l.qty_base), 0))}</td></tr></tfoot>
        </table>
        <div className="mt-10 grid grid-cols-3 gap-8 text-center"><div className="border-t border-black pt-1">Sent by</div><div className="border-t border-black pt-1">Driver</div><div className="border-t border-black pt-1">Received by</div></div>
      </div>
      <style>{`.print-sheet { width: 210mm; min-height: 148mm; } @page { size: A4; margin: 10mm; } @media print { .print-sheet { width: auto; min-height: 0; } body { background: white; } }`}</style>
    </div>
  );
}
