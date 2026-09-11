/**
 * Build public/seed/sample-import.xlsx — the file the Import screen offers as
 * "Download sample".
 *
 *   node scripts/make-sample-import.mjs
 *
 * One sheet per import target, named exactly as the screen names it, with the
 * headers the auto-mapper recognises and a few rows in this shop's own style so
 * the numbers look like something rather than Foo and Bar.
 *
 * Generated rather than committed as a binary blob nobody can diff: when a
 * target gains a field, this runs again and the sample is right, instead of
 * quietly teaching people a column list that no longer exists.
 */
import * as XLSX from 'xlsx';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'public/seed/sample-import.xlsx');

/**
 * Header text is the field LABEL from targets.ts, which autoMap() matches
 * before it tries the aliases — so what a person sees in the sample is what the
 * screen will have already mapped for them when they upload it.
 */
const SHEETS = [
  {
    name: 'Sections',
    rows: [
      ['Section name', 'Code', 'Sort order'],
      ['LADDU', 'S-1', 1],
      ['HOT ITEMS', 'S-2', 2],
      ['MIXTURE', 'S-3', 3],
      ['PACKING', 'S-4', 4],
    ],
  },
  {
    name: 'Items',
    rows: [
      ['Item code', 'Item name', 'Units per box', 'Pieces per unit', 'Pack type',
       'Section', 'MRP per piece', 'Unit rate', 'Purchase rate', 'Reorder level', 'Shelf life (days)'],
      ['8',   'HT. MYSOOR PAK(12) 32',    32, 12, 'JAR',  'S-2', 5,   42,  30,  10, 21],
      ['12',  'BOONDI LADDU (12) 48',     48, 12, 'JAR',  'S-1', 5,   40,  28,  10, 15],
      ['27A', 'SOAN PAPIDI (12) 30',      30, 12, 'L.B',  'S-1', 5,   38,  26,   5, 30],
      ['54',  'MIXING NICE (12) 32',      32, 12, 'L.B',  'S-3', 5,   36,  24,   5, 45],
      ['91',  'KAJU KATLI 250G',          10,  1, 'PACK', 'S-1', 300, 300, 220,  4, 20],
    ],
  },
  {
    name: 'Customers',
    rows: [
      ['Name / company', 'Mobile 1', 'Mobile 2', 'City / town', 'Address', 'Route',
       'Ledger code', 'Price group', 'Credit limit', 'Opening balance', 'WhatsApp opt-in'],
      ['P. SRINIVAS (MCL)',      '9849686746', '',           'MACHARLA',    'Main bazaar',    'Macherla line', 'C-41', 'Wholesale', 50000, 12400, 'yes'],
      ['MASTAN VALI',            '9000000002', '9000000012', 'TAKKELLAPADU', 'Near bus stand', 'Town',          'C-42', 'Wholesale', 40000,  2640, 'yes'],
      ['J.S.N MALLESWAR RAO',    '9000000003', '',           'GUNTUR',      'Kothapet',       'Guntur line',   'C-43', 'Retail',    25000,     0, 'yes'],
      ['SRI VENKATESWARA STORES','9000000004', '',           'TENALI',      'Market road',    'Guntur line',   'C-44', 'Retail',    15000,   980, 'no'],
    ],
  },
  {
    name: 'Opening stock',
    rows: [
      ['Item code', 'Opening (boxes)'],
      ['8',   26],
      ['12',  14.5],
      ['27A',  8],
      ['54',   0],
      // Negative on purpose: the real stock report had seven of these, and the
      // sample should not pretend the data is always tidy.
      ['91',  -2],
    ],
  },
  {
    /*
      One row per ingredient, product code repeated. The blank "Pieces per
      plate" cells are the point of the example: it belongs to the recipe, not
      to each ingredient, so it is written once and the rest of the group takes
      it — which is how anybody fills this in by hand.
    */
    name: 'Recipes',
    rows: [
      ['Product code', 'Pieces per plate', 'Ingredient code', 'Qty per plate', 'Unit', 'Recipe name'],
      ['8',  320, 'RM-BESAN', 12,  'KG', 'MYSORE PAK PLATE'],
      ['8',  '',  'RM-SUGAR', 8,   'KG', ''],
      ['8',  '',  'RM-GHEE',  500, 'G',  ''],
      ['12', 480, 'RM-BESAN', 10,  'KG', 'BOONDI LADDU PLATE'],
      ['12', '',  'RM-SUGAR', 9,   'KG', ''],
    ],
  },
  {
    name: 'Rates',
    rows: [
      ['Item code', 'Unit rate', 'Purchase rate'],
      ['8',   42,  30],
      ['12',  40,  28],
      ['27A', 38,  26],
      ['54',  36,  24],
      ['91', 300, 220],
    ],
  },
];

const wb = XLSX.utils.book_new();
for (const s of SHEETS) {
  const ws = XLSX.utils.aoa_to_sheet(s.rows);
  // Wide enough to read the headers without dragging every column out.
  ws['!cols'] = s.rows[0].map((h) => ({ wch: Math.max(12, String(h).length + 2) }));
  XLSX.utils.book_append_sheet(wb, ws, s.name);
}

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, XLSX.write(wb, { bookType: 'xlsx', type: 'buffer' }));
console.log(`wrote ${OUT} — ${SHEETS.length} sheets`);
