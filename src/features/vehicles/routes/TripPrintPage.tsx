import { useQuery } from '@tanstack/react-query';
import { Link, useParams } from 'react-router-dom';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { useMe } from '@/features/auth/hooks';
import { dateDMY, int, qty, toNumber } from '@/lib/format';
import { getTrip, tripLoadingSheet } from '../trips-api';

/** Van loading sheet — what the driver signs for before leaving. */
export function TripPrintPage() {
  const { id } = useParams();
  const me = useMe();
  const trip = useQuery({ queryKey: ['trips', 'one', id], queryFn: () => getTrip(id ?? ''), enabled: Boolean(id) });
  const sheet = useQuery({ queryKey: ['trips', 'sheet', id], queryFn: () => tripLoadingSheet(id ?? ''), enabled: Boolean(id) });
  if (trip.isLoading || sheet.isLoading) return <Spinner label="Preparing print…" full />;
  if (!trip.data || !sheet.data) return <p className="p-6 text-sm text-destructive">Trip not found.</p>;
  const t = trip.data;
  const totalBoxes = sheet.data.reduce((s, r) => s + toNumber(r.boxes), 0);

  return (
    <div className="min-h-screen bg-neutral-200 print:bg-white">
      <div className="no-print flex items-center justify-between gap-2 border-b bg-card px-4 py-2 text-sm">
        <Button asChild variant="ghost" size="sm"><Link to={`/vehicles/trips/${t.id}`}>← Back to trip</Link></Button>
        <Button size="sm" onClick={() => window.print()}>Print</Button>
      </div>
      <div className="print-sheet mx-auto my-4 bg-white p-8 text-[12px] leading-tight text-black print:my-0 print:p-6">
        <div className="text-center text-base font-bold tracking-wide">VAN LOADING SHEET</div>
        <div className="text-center text-xs text-neutral-700">{me.data?.org_name ?? 'JYOTHI FOODS'}</div>
        <div className="mt-2 grid grid-cols-2 gap-x-4 border border-black p-2">
          <div><span className="font-bold">Vehicle:</span> {t.vehicle_number}</div>
          <div><span className="font-bold">Date:</span> {dateDMY(t.trip_date)}</div>
          <div><span className="font-bold">Driver:</span> {t.driver_name ?? ''}</div>
          <div><span className="font-bold">Route:</span> {t.route_name ?? ''}</div>
          <div><span className="font-bold">Opening km:</span> {t.opening_km ?? ''}</div>
          <div><span className="font-bold">Status:</span> {t.status}</div>
        </div>
        <table className="mt-2 w-full border-collapse border border-black">
          <thead>
            <tr className="border-b border-black">
              <th className="w-10 border-r border-black p-1 text-left">S.No</th>
              <th className="w-16 border-r border-black p-1 text-left">CODE</th>
              <th className="border-r border-black p-1 text-left">Item Name</th>
              <th className="w-14 border-r border-black p-1 text-left">Pack</th>
              <th className="w-16 border-r border-black p-1 text-right">Jars</th>
              <th className="w-16 border-r border-black p-1 text-right">Boxes</th>
              <th className="w-16 border-r border-black p-1 text-right">Qty</th>
              <th className="w-20 p-1 text-right">Returned</th>
            </tr>
          </thead>
          <tbody>
            {sheet.data.map((r, i) => (
              <tr key={r.item_id ?? i}>
                <td className="border-r border-black px-1 text-center">{i + 1}</td>
                <td className="border-r border-black px-1">{r.item_code}</td>
                <td className="border-r border-black px-1">{r.item_name}</td>
                <td className="border-r border-black px-1">{r.pack ?? ''}</td>
                <td className="border-r border-black px-1 text-right tabular-nums">{int(r.units_per_box)}</td>
                <td className="border-r border-black px-1 text-right tabular-nums">{qty(r.boxes)}</td>
                <td className="border-r border-black px-1 text-right tabular-nums">{qty(r.units)}</td>
                <td className="px-1" />
              </tr>
            ))}
            {Array.from({ length: Math.max(0, 20 - sheet.data.length) }).map((_, i) => (
              <tr key={`pad-${i}`} className="h-4"><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td className="border-r border-black" /><td /></tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t border-black font-bold">
              <td colSpan={5} className="border-r border-black px-1 text-right">Total boxes:</td>
              <td className="border-r border-black px-1 text-right tabular-nums">{qty(totalBoxes)}</td>
              <td className="border-r border-black" /><td />
            </tr>
          </tfoot>
        </table>
        <div className="mt-10 grid grid-cols-3 text-center">
          <div>Loaded by</div><div>Driver</div><div>Checked by</div>
        </div>
      </div>
      <style>{`
        .print-sheet { width: 210mm; min-height: 297mm; }
        @page { size: A4; margin: 10mm; }
        @media print { .print-sheet { width: auto; min-height: 0; } body { background: white; } }
      `}</style>
    </div>
  );
}
