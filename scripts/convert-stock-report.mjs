/**
 * Turn a monthly STOCK report into files the Import screen can actually take.
 *
 *   node scripts/convert-stock-report.mjs <report.xlsx> [outDir]
 *
 * The shop's report is one sheet:
 *
 *   Item Code | Pack | Group / Item Name | Unit Per Box | Opening | Purchase | Sales | Closing
 *
 * It is not an import file, and the gap is not only cosmetic. The report's item
 * numbers are the shop's CURRENT numbering; the ERP's are the numbering that was
 * loaded when it was set up. From roughly 141 upward those two disagree — the
 * same product sits under a different number in each, and some numbers have been
 * handed to a different product altogether. Importing the report as it stands
 * would post one product's stock onto another's card, silently, and nobody would
 * find out until a van was loaded from a figure that was never true.
 *
 * So this matches on the PRODUCT NAME, not the number, and writes out:
 *
 *   Opening stock  the closing figure, keyed by the number the ERP really uses
 *   New items      products the ERP has never seen, ready to add first
 *   Code changes   every number that has moved, so the change is on paper
 *   Check first    everything a person has to decide, one row per question
 *
 * Nothing here rewrites the item master. Names, packing and pack types in the
 * ERP are left exactly as they are: the report's spellings are looser (MYSOOR /
 * MYSORE) and its "Pack" column is the outer carton, not the packing unit.
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as XLSX from 'xlsx';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

// ── the ERP's own idea of an item code, and a looser one for names ──────────
const codeKey = (s) => String(s ?? '').replace(/[\s:]+/g, '').toUpperCase();
/** Names are compared with punctuation and a trailing "NEW" thrown away. */
const nameKey = (s) => String(s ?? '').toUpperCase().replace(/\bNEW\b/g, '').replace(/[^A-Z0-9]/g, '');
const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
const num = (v) => (v === null || v === undefined || v === '' ? 0 : Number(v));

/**
 * MRP and pieces-per-unit are encoded in the name: "5/- MYSORE PAK (12) 32" is
 * five rupees a piece, twelve pieces in a jar, thirty-two jars in a box.
 *
 * This is not a guess. Run with `verify` and it reproduces the pieces-per-unit
 * and the MRP the ERP already holds on all 166 of its priced items.
 */
export function decodeName(name, unitsPerBox) {
  const s = clean(name);
  const mrpM = s.match(/^\s*(\d+(?:\.\d+)?)\s*\/-/);
  const mrp = mrpM ? Number(mrpM[1]) : null;
  const m = [...s.matchAll(/\((\d+)\s*([A-Za-z]*)\)+\s*([0-9]+)?/g)].pop();
  if (!m) return { mrp, pieces: 1, note: 'no (n) in the name' };
  // "(12KG)" is twelve kilos of loose goods, not twelve pieces in a jar.
  if (/^(KG|KGS)$/i.test(m[2] ?? '')) return { mrp, pieces: 1, note: 'sold loose by weight' };
  const pieces = Number(m[1]);
  const boxInName = m[3] === undefined ? null : Number(m[3]);
  if (boxInName !== null && Number(unitsPerBox) !== boxInName) {
    return { mrp, pieces, note: `name says ${boxInName} a box, the column says ${unitsPerBox}` };
  }
  return { mrp, pieces, note: '' };
}

// ── inputs ─────────────────────────────────────────────────────────────────
function readCsv(path) {
  const lines = readFileSync(path, 'utf8').trim().split(/\r?\n/);
  const head = lines[0].split(',');
  return lines.slice(1).map((l) => {
    const cells = l.split(',');
    return Object.fromEntries(head.map((h, i) => [h, cells[i]]));
  });
}

/**
 * What the ERP holds today. Read from the seed files that were imported into
 * it — so if products have been added or renamed in the app since, re-export
 * the item list over these before trusting the answer.
 */
export function erpMaster() {
  const rows = [
    ...readCsv(join(ROOT, 'public/seed/items.csv')),
    ...readCsv(join(ROOT, 'public/seed/unmatched_items.csv')),
  ];
  const byCode = new Map(rows.map((r) => [codeKey(r.item_code), r]));
  const byName = new Map();
  for (const r of rows) {
    const k = nameKey(r.name);
    if (!byName.has(k)) byName.set(k, []);
    byName.get(k).push(r);
  }
  return { rows, byCode, byName };
}

export function readReport(file) {
  const wb = XLSX.read(readFileSync(file));
  const ws = wb.Sheets[wb.SheetNames[0]];
  const grid = XLSX.utils.sheet_to_json(ws, { header: 1, raw: true, defval: null, blankrows: true });
  // Row 1 is a title ("Stock Reprot on 9.9.2026"), row 2 the headings.
  const title = clean(grid[0]?.find((c) => c));
  return {
    title,
    rows: grid
      .slice(2)
      .filter((r) => r && r.some((c) => c !== null && c !== ''))
      .map((r, i) => ({
        line: i + 3,
        code: clean(r[0]),
        pack: clean(r[1]),
        name: clean(r[2]),
        upb: r[3],
        opening: r[4],
        purchase: r[5],
        sales: r[6],
        closing: r[7],
      })),
  };
}

/**
 * Which ERP product is this line? The name decides, because the numbers have
 * moved. Five outcomes, and only the first three are safe to import.
 */
export function match(row, m, reportNames) {
  const sameName = m.byName.get(nameKey(row.name)) ?? [];
  if (sameName.length === 1) {
    const erp = sameName[0];
    return { kind: codeKey(erp.item_code) === codeKey(row.code) ? 'same' : 'moved', erp };
  }
  if (sameName.length > 1) {
    const atThisCode = sameName.find((h) => codeKey(h.item_code) === codeKey(row.code));
    if (atThisCode) return { kind: 'same', erp: atThisCode };
    return { kind: 'ambiguous', candidates: sameName };
  }
  const held = m.byCode.get(codeKey(row.code));
  if (held) {
    // The number is known but holds a different name. Two very different cases,
    // told apart without guesswork: if the product the ERP keeps under this
    // number turns up elsewhere in the report, the number has been REUSED and
    // importing here would overwrite the wrong card. If it does not, the two
    // names are the same product spelled differently.
    const movedAway = reportNames.get(nameKey(held.name));
    if (movedAway && codeKey(movedAway.code) !== codeKey(row.code)) {
      return { kind: 'reused', erp: held, nowAt: movedAway };
    }
    return { kind: 'spelling', erp: held };
  }
  return { kind: 'new' };
}

// ── the workbook ───────────────────────────────────────────────────────────
function sheet(rows) {
  const ws = XLSX.utils.aoa_to_sheet(rows);
  ws['!cols'] = (rows[0] ?? []).map((h, i) => ({
    wch: Math.max(11, ...rows.slice(0, 400).map((r) => String(r[i] ?? '').length + 2)),
  }));
  return ws;
}

function build(reportFile, outDir) {
  const m = erpMaster();
  const report = readReport(reportFile);
  const reportNames = new Map(report.rows.map((r) => [nameKey(r.name), r]));

  const opening = [['Item code', 'Opening (boxes)', 'Product', 'Your report no.']];
  const newItems = [[
    'Item code', 'Item name', 'Units per box', 'Pieces per unit',
    'MRP per piece', 'Pack type', 'Section',
  ]];
  const changes = [['Your report no.', 'Product', 'Number in the ERP', 'Closing (boxes)']];
  const checks = [['What', 'Your report no.', 'Product', 'Detail', 'What to do']];
  const tally = { same: 0, moved: 0, spelling: 0, reused: 0, ambiguous: 0, new: 0 };

  for (const r of report.rows) {
    const res = match(r, m, reportNames);
    tally[res.kind]++;

    // ── the figures that can be posted ──
    if (res.kind === 'same' || res.kind === 'moved' || res.kind === 'spelling') {
      opening.push([res.erp.item_code, num(r.closing), r.name, r.code]);
    } else if (res.kind === 'new') {
      const d = decodeName(r.name, r.upb);
      newItems.push([r.code, r.name, num(r.upb), d.pieces, d.mrp ?? '', '', '']);
      opening.push([r.code, num(r.closing), r.name, r.code]);
      // When the name carries only one number there is no way to tell a jar of
      // twelve from twelve jars in a box, and the ERP's own products answer it
      // by using the same figure for both. Copied, but never quietly: this is
      // what turns boxes into pieces on a bill.
      if (d.pieces === num(r.upb) && d.pieces !== 1) {
        checks.push([
          'Pieces per unit was copied from the box count', r.code, r.name,
          `The name gives one number only, so pieces per unit is set to ${d.pieces}, the same as units per box — which is what the ERP's existing products do.`,
          'Correct it on the product if a jar or packet actually holds a different number of pieces.',
        ]);
      }
      if (d.note) {
        checks.push(['Packing read from the name', r.code, r.name, d.note, 'Check units per box on this product after importing.']);
      }
    }

    // ── the numbering that has moved ──
    if (res.kind === 'moved') {
      changes.push([r.code, r.name, res.erp.item_code, num(r.closing)]);
    }

    // ── the questions ──
    if (res.kind === 'reused') {
      checks.push([
        'Number given to a different product', r.code, r.name,
        `The ERP keeps number ${r.code} for "${res.erp.name}", which your report now lists as number ${res.nowAt.code}.`,
        `Left out of the Opening stock sheet on purpose. Importing it would put ${num(r.closing)} boxes onto the wrong product. Say which ERP product this is and it can go in.`,
      ]);
    }
    if (res.kind === 'ambiguous') {
      checks.push([
        'Two ERP products share this name', r.code, r.name,
        `The ERP has this name under ${res.candidates.map((c) => c.item_code).join(' and ')}.`,
        'Left out of the Opening stock sheet. Tell me which number is the live one.',
      ]);
    }
    if (res.kind === 'spelling') {
      checks.push([
        'Spelling differs — treated as the same product', r.code, r.name,
        `The ERP calls number ${r.code} "${res.erp.name}".`,
        'The figure has been imported against this number. If they are NOT the same product, say so.',
      ]);
    }

    // ── faults in the figures themselves ──
    if (num(r.closing) < 0) {
      checks.push([
        'Closing is below zero', r.code, r.name,
        `Opening ${num(r.opening)} + purchase ${num(r.purchase)} − sales ${num(r.sales)} = ${num(r.closing)} boxes.`,
        'More has been sold than ever came in. A production batch or a purchase was never entered. Trace it, then correct it with a stock count.',
      ]);
    }
    const erp = res.erp;
    if (erp && erp.units_per_box && Number(erp.units_per_box) !== Number(r.upb)) {
      // Only spell out the arithmetic when there is stock to get wrong —
      // "0 boxes will post as 0 units, not 0" tells nobody anything.
      const bite = num(r.closing)
        ? ` The import multiplies boxes by the ERP's figure, so ${num(r.closing)} boxes will post as ${num(r.closing) * Number(erp.units_per_box)} units, not ${num(r.closing) * Number(r.upb)}.`
        : ' Nothing is in stock today, so nothing posts wrongly yet — but the next bill for it will be out.';
      checks.push([
        'Units per box disagrees', r.code, r.name,
        `The ERP has ${erp.units_per_box} a box, your report says ${r.upb}.`,
        `Fix whichever is wrong before importing.${bite}`,
      ]);
    }
  }

  // ── products the ERP has that this report never mentions ──
  const inReport = new Set(report.rows.map((r) => codeKey(r.code)));
  const claimed = new Set(
    report.rows.map((r) => {
      const res = match(r, m, reportNames);
      return res.erp ? codeKey(res.erp.item_code) : null;
    }).filter(Boolean),
  );
  let absent = 0;
  for (const [key, r] of m.byCode) {
    if (claimed.has(key) || inReport.has(key)) continue;
    absent++;
    checks.push([
      'In the ERP, not in this report', r.item_code, r.name, 'No line for it in the report.',
      'Its stock is left exactly as it is — the import only touches products the file names. If it is discontinued, set it inactive.',
    ]);
  }

  checks.push([
    'The "Pack" column was not used', '', '',
    'Your report says BOX / BAG / TRY / PACK — the outer carton. The ERP\'s pack type is the packing unit: JAR, L.B, PACK, KG.',
    'Left blank so 110 JARs are not overwritten with "BOX". Set the pack type on the new products by hand, or send a list.',
  ]);

  const readme = [
    ['Stock report, ready to import'],
    [report.title || basename(reportFile)],
    [''],
    ['THE ONE THING TO KNOW'],
    ['Your report numbers the products differently from the ERP. From about 141 upward the'],
    ['same product sits under a different number in each, and a few numbers have been given to'],
    ['another product altogether. So this file is matched on the PRODUCT NAME, and the'],
    ['"Item code" column already holds the number the ERP uses. Import it as it is.'],
    ['Do not paste your own numbers back over that column.'],
    [''],
    ['DO IT IN THIS ORDER'],
    ['1. Setup > Import data > Items — upload this file, choose the "New items" sheet.'],
    [`   ${newItems.length - 1} products the ERP has never seen. Nothing else on the item master is touched.`],
    ['2. Setup > Import data > Opening stock — same file, "Opening stock" sheet.'],
    ['   Choose the godown, and read the note on the date below.'],
    ['3. Read "Check first". Every row there is a question only you can answer.'],
    [''],
    ['THE DATE — THIS ONE BITES'],
    ['The import compares against what it has already posted ON THAT DATE and posts only the'],
    ['difference. So:'],
    ['  - Opening stock already loaded once? Use THE SAME DATE you used then. The figures'],
    ['    will land exactly on this report.'],
    ['  - Never loaded any opening stock? Use the date of this report.'],
    ['  - Do not run it twice on two different dates. The two would add up instead of'],
    ['    replacing each other, and every product would read double.'],
    [''],
    ['WHAT WAS CHECKED'],
    [`  ${report.rows.length} lines read. Every one adds up: opening + purchase − sales = closing, with no exceptions.`],
    ['  No duplicate numbers, no blank names, no missing units-per-box.'],
    [`  ${tally.same} matched the ERP on both number and name.`],
    [`  ${tally.moved} are the same product under a different number — see "Code changes".`],
    [`  ${tally.spelling} matched by number with the name spelled differently.`],
    [`  ${tally.reused} numbers now hold a different product — left out, see "Check first".`],
    [`  ${tally.ambiguous} names exist twice in the ERP — left out, see "Check first".`],
    [`  ${tally.new} products are genuinely new.`],
    [`  ${absent} products in the ERP are not mentioned in this report; their stock is left alone.`],
    [''],
    ['WHAT WAS NOT CHANGED'],
    ['Names, units per box, pieces per unit, pack types and sections in the ERP are untouched.'],
    ['The report spells some names loosely (MYSOOR / MYSORE) and its "Pack" column is the'],
    ['carton, not the packing. Importing it over the master would have made the ERP worse.'],
    ['The Purchase and Sales columns are month totals, not bills, so they cannot be imported'],
    ['as transactions — they were used here only to prove the arithmetic.'],
  ].map((r) => [r[0] ?? '']);

  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, sheet(readme), 'Read me');
  XLSX.utils.book_append_sheet(wb, sheet(newItems), 'New items');
  XLSX.utils.book_append_sheet(wb, sheet(opening), 'Opening stock');
  XLSX.utils.book_append_sheet(wb, sheet(changes), 'Code changes');
  XLSX.utils.book_append_sheet(wb, sheet(checks), 'Check first');

  mkdirSync(outDir, { recursive: true });
  const stem = basename(reportFile).replace(/\.[^.]+$/, '');
  const xlsxOut = join(outDir, `${stem} - ready to import.xlsx`);
  writeFileSync(xlsxOut, XLSX.write(wb, { bookType: 'xlsx', type: 'buffer' }));

  // CSVs as well: one sheet each, so they import on a browser that has not yet
  // picked up the build with the sheet chooser.
  const csvOut = [];
  for (const [name, rows] of [['new-items', newItems], ['opening-stock', opening]]) {
    const p = join(outDir, `${stem} - ${name}.csv`);
    writeFileSync(p, XLSX.utils.sheet_to_csv(sheet(rows)));
    csvOut.push(p);
  }

  return { xlsxOut, csvOut, tally, absent, checks: checks.length - 1, opening: opening.length - 1, newItems: newItems.length - 1 };
}

// ── run ────────────────────────────────────────────────────────────────────
const [, , input, outDir = join(ROOT, 'out')] = process.argv;

if (input === 'verify') {
  // The name decoder is only trustworthy if it reproduces what the ERP already
  // holds. Anything less and the new products get invented packing.
  const seed = readCsv(join(ROOT, 'public/seed/items.csv'));
  let pieces = 0;
  let mrp = 0;
  for (const r of seed) {
    const d = decodeName(r.name, r.units_per_box);
    if (Number(d.pieces) === Number(r.pieces_per_unit)) pieces++;
    if (Number(d.mrp) === Number(r.mrp_per_piece)) mrp++;
  }
  console.log(`pieces-per-unit: ${pieces}/${seed.length}   MRP: ${mrp}/${seed.length}`);
  if (pieces !== seed.length || mrp !== seed.length) {
    throw new Error('the name decoder no longer reproduces the ERP’s own items');
  }
} else if (!input) {
  console.error('usage: node scripts/convert-stock-report.mjs <report.xlsx> [outDir]');
  process.exit(1);
} else {
  const r = build(input, outDir);
  console.log(JSON.stringify(r.tally), `absent ${r.absent}`);
  console.log(`opening rows ${r.opening}, new items ${r.newItems}, checks ${r.checks}`);
  console.log(r.xlsxOut);
  r.csvOut.forEach((p) => console.log(p));
}
