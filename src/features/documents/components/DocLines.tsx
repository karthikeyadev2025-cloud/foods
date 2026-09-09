import { Trash2 } from 'lucide-react';
import { useRef, useState } from 'react';
import { Combobox } from '@/components/Combobox';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { effectiveUnitRate, searchItems, type ItemRow } from '@/features/items/api';
import { amount, int, qty, toNumber } from '@/lib/format';
import { invoiceLine, invoiceTotals } from '@/lib/units';
import { nextLineKey, type DocLine } from '../api';

/**
 * The client's grid on every document: S.No | CODE | Item Name | Jars | Boxes | Qty | Rate | Total.
 * CODE → Boxes → Rate typed; the rest read from the master. `showRate` off for challans.
 */
export function DocLines({ lines, onChange, editable, customerId, date, showRate = true, rateSource = 'sale' }: {
  lines: DocLine[];
  onChange: (lines: DocLine[]) => void;
  editable: boolean;
  customerId?: string | null;
  date?: string;
  showRate?: boolean;
  rateSource?: 'sale' | 'purchase';
}) {
  const [entryItem, setEntryItem] = useState<ItemRow | null>(null);
  const [entryBoxes, setEntryBoxes] = useState('');
  const [entryRate, setEntryRate] = useState('');
  const boxesRef = useRef<HTMLInputElement>(null);
  const rateRef = useRef<HTMLInputElement>(null);
  const codeWrapRef = useRef<HTMLDivElement>(null);
  const computed = lines.map((l) => invoiceLine({ boxes: l.boxes, rate: showRate ? l.rate : 0, unitsPerBox: l.units_per_box }));
  const totals = invoiceTotals(computed);
  const focusCode = () => codeWrapRef.current?.querySelector('input')?.focus();

  const onItemPicked = async (item: ItemRow) => {
    setEntryItem(item);
    let rate = rateSource === 'purchase' ? toNumber(item.purchase_rate) : toNumber(item.unit_rate);
    if (rateSource === 'sale' && customerId && item.id) {
      try {
        rate = await effectiveUnitRate(item.id, customerId, date || new Date().toISOString().slice(0, 10));
      } catch {
        /* master rate stays */
      }
    }
    setEntryRate(rate ? String(rate) : '');
    setEntryBoxes('');
    setTimeout(() => boxesRef.current?.focus(), 0);
  };
  const addEntry = () => {
    const boxes = toNumber(entryBoxes);
    if (!entryItem?.id || !entryItem.units_per_box || boxes <= 0) { boxesRef.current?.focus(); return; }
    onChange([...lines, { key: nextLineKey(), item_id: entryItem.id, item_code: entryItem.item_code ?? '', item_name: entryItem.name ?? '', units_per_box: entryItem.units_per_box, boxes, rate: toNumber(entryRate) }]);
    setEntryItem(null); setEntryBoxes(''); setEntryRate('');
    setTimeout(focusCode, 0);
  };
  const update = (key: string, patch: Partial<DocLine>) => onChange(lines.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  return (
    <div className="rounded-md border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-12">S.No</TableHead><TableHead className="w-40">CODE</TableHead><TableHead>Item Name</TableHead>
            <TableHead className="w-20 text-right">Jars</TableHead><TableHead className="w-24 text-right">Boxes</TableHead><TableHead className="w-24 text-right">Qty</TableHead>
            {showRate && <TableHead className="w-28 text-right">Rate</TableHead>}{showRate && <TableHead className="w-32 text-right">Total</TableHead>}
            {editable && <TableHead className="w-10" />}
          </TableRow>
        </TableHeader>
        <TableBody>
          {lines.map((l, i) => (
            <TableRow key={l.key}>
              <TableCell className="num">{i + 1}</TableCell>
              <TableCell className="font-medium">{l.item_code}</TableCell>
              <TableCell>{l.item_name}</TableCell>
              <TableCell className="num text-muted-foreground">{qty(l.units_per_box)}</TableCell>
              <TableCell className="num">{editable ? <Input type="number" step="0.001" className="num h-8" aria-label={`Boxes for ${l.item_code}`} value={l.boxes} onChange={(ev) => update(l.key, { boxes: toNumber(ev.target.value) })} /> : qty(l.boxes)}</TableCell>
              <TableCell className="num text-muted-foreground">{qty(computed[i]?.qty)}</TableCell>
              {showRate && <TableCell className="num">{editable ? <Input type="number" step="0.01" className="num h-8" aria-label={`Rate for ${l.item_code}`} value={l.rate} onChange={(ev) => update(l.key, { rate: toNumber(ev.target.value) })} /> : amount(l.rate)}</TableCell>}
              {showRate && <TableCell className="num font-medium">{amount(computed[i]?.total)}</TableCell>}
              {editable && <TableCell><Button type="button" variant="ghost" size="icon" aria-label={`Remove ${l.item_code}`} onClick={() => onChange(lines.filter((x) => x.key !== l.key))}><Trash2 className="text-destructive" /></Button></TableCell>}
            </TableRow>
          ))}
          {editable && (
            <TableRow className="bg-muted/30">
              <TableCell className="num text-muted-foreground">{lines.length + 1}</TableCell>
              <TableCell>
                <div ref={codeWrapRef}>
                  <Combobox<ItemRow> value={entryItem} onChange={setEntryItem} search={(q) => searchItems(q, { finishedOnly: rateSource === 'sale' })} queryKey={rateSource === 'sale' ? 'items' : 'items-all'} getKey={(it) => it.id ?? ''} getLabel={(it) => it.item_code ?? ''} renderOption={(it) => <span><span className="font-medium">{it.item_code}</span> {it.name}<span className="text-muted-foreground"> · {it.units_per_box}/box</span></span>} placeholder="Code or name" aria-label="Item code or name" onPicked={onItemPicked} />
                </div>
              </TableCell>
              <TableCell className="text-muted-foreground">{entryItem?.name ?? 'Type a code or name, Enter to pick'}</TableCell>
              <TableCell className="num text-muted-foreground">{entryItem ? qty(entryItem.units_per_box) : ''}</TableCell>
              <TableCell><Input ref={boxesRef} type="number" step="0.001" className="num h-8" aria-label="Boxes" value={entryBoxes} onChange={(ev) => setEntryBoxes(ev.target.value)} onKeyDown={(ev) => { if (ev.key === 'Enter') { ev.preventDefault(); if (showRate) rateRef.current?.focus(); else addEntry(); } }} disabled={!entryItem} /></TableCell>
              <TableCell className="num text-muted-foreground">{entryItem && entryBoxes ? qty(toNumber(entryBoxes) * (entryItem.units_per_box ?? 0)) : ''}</TableCell>
              {showRate && <TableCell><Input ref={rateRef} type="number" step="0.01" className="num h-8" aria-label="Rate" value={entryRate} onChange={(ev) => setEntryRate(ev.target.value)} onKeyDown={(ev) => { if (ev.key === 'Enter') { ev.preventDefault(); addEntry(); } }} disabled={!entryItem} /></TableCell>}
              {showRate && <TableCell className="num text-muted-foreground">{entryItem && entryBoxes ? amount(toNumber(entryBoxes) * (entryItem.units_per_box ?? 0) * toNumber(entryRate)) : ''}</TableCell>}
              <TableCell><Button type="button" size="sm" variant="secondary" onClick={addEntry} disabled={!entryItem}>Add</Button></TableCell>
            </TableRow>
          )}
        </TableBody>
        <TableFooter>
          <TableRow>
            <TableCell colSpan={4} className="text-right">Total</TableCell>
            <TableCell className="num">{qty(totals.totalBoxes)}</TableCell><TableCell className="num">{int(totals.totalQty)}</TableCell>
            {showRate && <TableCell />}{showRate && <TableCell className="num">{amount(totals.netAmount)}</TableCell>}
            {editable && <TableCell />}
          </TableRow>
        </TableFooter>
      </Table>
    </div>
  );
}
