import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { amount, qty } from '@/lib/format';
import { amountInWords } from '@/lib/money';
import { fillTerms, showField, type PrintOrg, type PrintTemplateLike } from './template';

/**
 * The one printed sheet for invoice, quotation and challan. What it shows is decided by
 * the org's print template (Setup → Print designer): paper size, which blocks and
 * columns appear, the numbered terms, header and footer lines, logo and signature.
 * The trade terms themselves still come from the business profile (DOMAIN_RULES.md 12).
 */
export interface PrintLine {
  key: string;
  code: string;
  name: string;
  units_per_box: number;
  boxes: number;
  qty: number;
  rate: number;
  amount: number;
}

export interface PrintTotals {
  discount: number;
  freight: number;
  round_off: number;
  total: number;
}

export interface SalesDocPrintProps {
  title: string;
  org: PrintOrg | null | undefined;
  template: PrintTemplateLike | null | undefined;
  party: { name: string; town: string; phones: string };
  /** Right-hand header block: date, number, transport, L.R… in order. */
  meta: { label: string; value: string; bold?: boolean; transport?: boolean }[];
  lines: PrintLine[];
  /** Null on a challan: no money on the sheet. */
  totals: PrintTotals | null;
  backTo?: string;
  backLabel?: string;
  /** Inside the designer: no toolbar, no page chrome. */
  preview?: boolean;
}

type PaperSpec = { width: string; minHeight: string; page: string; pad: number; font: string; thermal: boolean };
const PAPER: Record<string, PaperSpec> = {
  A4: { width: '210mm', minHeight: '297mm', page: 'A4', pad: 18, font: '12px', thermal: false },
  A5: { width: '148mm', minHeight: '210mm', page: 'A5', pad: 10, font: '10.5px', thermal: false },
  thermal_80: { width: '72mm', minHeight: '0', page: '80mm auto', pad: 0, font: '10px', thermal: true },
  thermal_58: { width: '48mm', minHeight: '0', page: '58mm auto', pad: 0, font: '8.5px', thermal: true },
};

export function SalesDocPrint({ title, org, template, party, meta, lines, totals, backTo, backLabel, preview }: SalesDocPrintProps) {
  const paper = PAPER[template?.paper ?? 'A4'] ?? PAPER.A4!;
  const show = (k: string) => showField(template, k);
  const money = totals !== null;
  const cols = {
    code: show('code'),
    jars: show('jars'),
    qty: show('qty'),
    rate: money && show('rate'),
    amount: money && show('amount'),
  };
  const colCount = 3 + Number(cols.code) + Number(cols.jars) + Number(cols.qty) + Number(cols.rate) + Number(cols.amount) - 1;
  const totalBoxes = lines.reduce((s, l) => s + l.boxes, 0);
  const terms = fillTerms(template?.terms, org);
  const cell = 'border-r border-black px-1';
  const orgName = org?.org_name ?? 'JYOTHI FOODS';
  const contact = [
    show('address') && org?.address ? org.address : null,
    show('address') && org?.org_phone ? `Ph ${org.org_phone}` : null,
    show('fssai') && org?.fssai_no ? `FSSAI ${org.fssai_no}` : null,
    show('email') && org?.org_email ? org.org_email : null,
  ].filter(Boolean);

  const sheet = (
    <div
      className={`print-sheet ${preview ? '' : 'mx-auto my-4 print:my-0'} bg-white leading-tight text-black`}
      style={{ width: paper.width, minHeight: paper.minHeight, fontSize: paper.font, padding: paper.thermal ? '2mm' : preview ? '8mm' : '10mm' }}
    >
      <div className={`flex ${paper.thermal ? 'flex-col items-center' : 'items-center gap-3'}`}>
        {show('logo') && org?.logo_url && <img src={org.logo_url} alt="" className="max-h-16 max-w-[30mm] object-contain" />}
        <div className="flex-1 text-center">
          <div className="text-base font-bold tracking-wide">{orgName}</div>
          {show('tagline') && org?.tagline && <div className="text-xs italic text-neutral-700">{org.tagline}</div>}
          {contact.length > 0 && <div className="text-xs text-neutral-700">{contact.join(' · ')}</div>}
          {template?.header_html && <div className="whitespace-pre-line text-xs">{template.header_html}</div>}
        </div>
      </div>
      <div className="mt-1 text-center text-sm font-bold tracking-wide">{title}</div>

      <div className={`mt-2 border border-black ${paper.thermal ? '' : 'grid grid-cols-2'}`}>
        <div className={`${paper.thermal ? 'border-b' : 'border-r'} border-black p-2`}>
          <div className="font-bold">{party.name}</div>
          <div>{party.town}</div>
          {show('phones') && party.phones && <div>PH NO : {party.phones}</div>}
        </div>
        <div className="p-2">
          {meta
            .filter((m) => !m.transport || show('transport'))
            .map((m) => (
              <div key={m.label} className="flex justify-between gap-2">
                <span className={m.bold ? 'font-bold' : ''}>{m.label}</span>
                <span>{m.value}</span>
              </div>
            ))}
        </div>
      </div>

      <table className="mt-2 w-full border-collapse border border-black">
        <thead>
          <tr className="border-b border-black">
            <th className={`w-8 ${cell} text-left`}>S.No</th>
            {cols.code && <th className={`w-14 ${cell} text-left`}>CODE</th>}
            <th className={`${cell} text-left`}>Item Name</th>
            {cols.jars && <th className={`w-12 ${cell} text-right`}>Jars</th>}
            <th className={`w-14 ${cell} text-right`}>Boxes</th>
            {cols.qty && <th className={`w-14 ${cell} text-right`}>Qty</th>}
            {cols.rate && <th className={`w-14 ${cell} text-right`}>Rate</th>}
            {cols.amount && <th className="w-20 px-1 text-right">Total</th>}
          </tr>
        </thead>
        <tbody>
          {lines.map((l, i) => (
            <tr key={l.key}>
              <td className={`${cell} text-center`}>{i + 1}</td>
              {cols.code && <td className={cell}>{l.code}</td>}
              <td className={cell}>{l.name}</td>
              {cols.jars && <td className={`${cell} text-right tabular-nums`}>{qty(l.units_per_box)}</td>}
              <td className={`${cell} text-right tabular-nums`}>{qty(l.boxes)}</td>
              {cols.qty && <td className={`${cell} text-right tabular-nums`}>{qty(l.qty)}</td>}
              {cols.rate && <td className={`${cell} text-right tabular-nums`}>{amount(l.rate)}</td>}
              {cols.amount && <td className="px-1 text-right tabular-nums">{amount(l.amount)}</td>}
            </tr>
          ))}
          {Array.from({ length: Math.max(0, paper.pad - lines.length) }).map((_, i) => (
            <tr key={`pad-${i}`} className="h-4">
              {Array.from({ length: colCount + 1 }).map((__, j) => (
                <td key={j} className={j < colCount ? 'border-r border-black' : ''} />
              ))}
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr className="border-t border-black font-bold">
            <td colSpan={2 + Number(cols.code) + Number(cols.jars)} className={`${cell} text-right`}>Total:</td>
            <td className={`${cell} text-right tabular-nums`}>{qty(totalBoxes)}</td>
            {/* No quantity total: it would add pieces of one item to jars of another. */}
            {cols.qty && <td className={cell} />}
            {cols.rate && <td className={cell} />}
            {cols.amount && <td />}
          </tr>
        </tfoot>
      </table>

      {totals && (
        <div className={`mt-1 border border-black ${paper.thermal ? '' : 'grid grid-cols-[1fr_auto]'}`}>
          {show('words') && (
            <div className={`${paper.thermal ? 'border-b' : 'border-r'} border-black p-1`}>
              <div className="font-bold">Total amount in words :</div>
              <div>{amountInWords(totals.total)}</div>
            </div>
          )}
          <div className="p-1 text-right">
            {show('charges') && totals.discount > 0 && <div>Discount : {amount(totals.discount)}</div>}
            {show('charges') && totals.freight > 0 && <div>Freight : {amount(totals.freight)}</div>}
            {show('charges') && totals.round_off !== 0 && <div>Round off : {amount(totals.round_off)}</div>}
            <div className="text-sm font-bold">
              Net Amount : <span className="ml-4 tabular-nums">{amount(totals.total)}</span>
            </div>
          </div>
        </div>
      )}

      {show('bank') && org?.bank_details && (
        <div className="mt-1 whitespace-pre-line border border-black p-1 text-xs">
          <span className="font-bold">Bank : </span>
          {org.bank_details}
        </div>
      )}

      <div className="mt-1 flex justify-between border border-black p-1">
        <span className="font-bold">E&amp;E.O</span>
        <span>For {orgName}</span>
      </div>

      {show('terms') && terms.length > 0 && (
        <ol className="mt-2 list-decimal space-y-0.5 pl-5">
          {terms.map((t, i) => (
            <li key={i} className={i === 0 ? 'font-bold' : ''}>
              {t}
            </li>
          ))}
        </ol>
      )}

      {template?.footer_html && <div className="mt-2 whitespace-pre-line text-xs">{template.footer_html}</div>}

      <div className={`mt-6 flex items-end justify-between ${paper.thermal ? 'flex-col items-center gap-2' : ''}`}>
        {show('thanks') ? <div className="text-center font-bold">THANKING YOU FOR SHOPPING &amp; VISIT AGAIN</div> : <div />}
        <div className="text-center">
          {show('signature') && org?.signature_url && <img src={org.signature_url} alt="" className="mx-auto mb-1 max-h-12 max-w-[35mm] object-contain" />}
          <div>Authorised Signatory.</div>
        </div>
      </div>
    </div>
  );

  if (preview) return sheet;

  return (
    <div className="min-h-screen bg-neutral-200 print:bg-white">
      <div className="no-print flex items-center justify-between gap-2 border-b bg-card px-4 py-2 text-sm">
        {backTo ? (
          <Button asChild variant="ghost" size="sm">
            <Link to={backTo}>← {backLabel ?? 'Back'}</Link>
          </Button>
        ) : (
          <span />
        )}
        <span className="text-xs text-muted-foreground">{PAPER[template?.paper ?? 'A4'] ? (template?.paper ?? 'A4').replace('_', ' ') : 'A4'}</span>
        <Button size="sm" onClick={() => window.print()}>
          Print
        </Button>
      </div>
      {sheet}
      <style>{`
        @page { size: ${paper.page}; margin: ${paper.thermal ? '2mm' : '10mm'}; }
        @media print {
          .print-sheet { width: auto !important; min-height: 0 !important; padding: 0 !important; box-shadow: none; }
          body { background: white; }
        }
      `}</style>
    </div>
  );
}
