import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as XLSX from 'xlsx';
import { exportToExcel, fileName, sheetName } from './export';

/**
 * Catch the workbook on its way to disk. Nothing is written in a test, and
 * writeFile cannot be spied on after the fact — an ES module's exports are not
 * configurable — so it is replaced when the module loads.
 */
const written = vi.hoisted(() => [] as XLSX.WorkBook[]);
vi.mock('xlsx', async (importOriginal) => {
  const actual = await importOriginal<typeof import('xlsx')>();
  return { ...actual, writeFile: (wb: XLSX.WorkBook) => { written.push(wb); } };
});

describe('sheetName', () => {
  // The one from the shop: Production → Batch → Excel did nothing at all,
  // because the product is called "5/- H.T MYSORE PAK".
  it('survives a product name with a slash in it', () => {
    expect(sheetName('5/- H.T MYSORE PAK')).toBe('5 - H.T MYSORE PAK');
  });

  it('removes every character Excel refuses', () => {
    expect(sheetName('a:b\\c/d?e*f[g]h')).toBe('a b c d e f g h');
  });

  it('keeps the word boundary rather than running words together', () => {
    expect(sheetName('Cash:Bank')).toBe('Cash Bank');
  });

  it('cuts to 31 characters and does not leave a space on the end', () => {
    const s = sheetName('HOME TYPE MYSORE PAK SPECIAL EXTRA');
    expect(s.length).toBeLessThanOrEqual(31);
    expect(s).toBe('HOME TYPE MYSORE PAK SPECIAL EX');
  });

  it('falls back when the name is nothing but banned characters', () => {
    expect(sheetName('///')).toBe('Sheet1');
    expect(sheetName('   ')).toBe('Sheet1');
  });

  it('will not start or end with an apostrophe', () => {
    expect(sheetName("'Ledger'")).toBe('Ledger');
  });

  it('avoids the name Excel reserves', () => {
    expect(sheetName('History')).toBe('History of');
    expect(sheetName('history')).toBe('History of');
  });

  it('leaves an ordinary name exactly as it is', () => {
    expect(sheetName('Batches')).toBe('Batches');
  });
});

describe('fileName', () => {
  it('strips a slash so the download is one file, not a folder', () => {
    expect(fileName('ledger-5/- MYSORE PAK')).toBe('ledger-5 - MYSORE PAK');
  });

  it('removes what Windows refuses', () => {
    expect(fileName('a<b>c:d"e|f?g*h')).toBe('a b c d e f g h');
  });

  it('drops a trailing dot or space that Windows would eat anyway', () => {
    expect(fileName('batch 0009. ')).toBe('batch 0009');
  });

  it('falls back rather than downloading a nameless file', () => {
    expect(fileName('??')).toBe('export');
  });

  it('leaves an ordinary name alone', () => {
    expect(fileName('receipts-2026-09-17')).toBe('receipts-2026-09-17');
  });
});

/**
 * "they want expected and actual boxes of batches in excel."
 *
 * A batch's boxes do not belong in its ingredient grid — dropped there they sit
 * under a heading that means something else — so they go on a tab of their own,
 * and the helper had to learn to write more than one.
 */
describe('exportToExcel with a second tab', () => {
  function captured(fn: () => void): XLSX.WorkBook {
    fn();
    const wb = written.at(-1);
    if (!wb) throw new Error('nothing was written');
    return wb;
  }

  beforeEach(() => { written.length = 0; });

  it('writes both tabs, in order, with the rows each was given', () => {
    const wb = captured(() =>
      exportToExcel('batch-0009', [{ Ingredients: 'SUGAR', Quantity: 12 }], '1/- KALAJAM(12)', [
        { name: 'Boxes', rows: [{ 'Expected boxes': 46, 'Actual boxes': 44, 'Variance (boxes)': -2 }] },
      ]),
    );
    // The product's slash is cleaned here too — a second tab is no reason for
    // the whole download to die.
    expect(wb.SheetNames).toEqual(['1 - KALAJAM(12)', 'Boxes']);
    const boxes = wb.Sheets['Boxes'];
    expect(boxes).toBeDefined();
    expect(XLSX.utils.sheet_to_json(boxes as XLSX.WorkSheet)).toEqual([
      { 'Expected boxes': 46, 'Actual boxes': 44, 'Variance (boxes)': -2 },
    ]);
  });

  it('numbers a tab whose name the first one already took', () => {
    const wb = captured(() => exportToExcel('x', [{ a: 1 }], 'Boxes', [{ name: 'Boxes', rows: [{ b: 2 }] }]));
    expect(wb.SheetNames).toEqual(['Boxes', 'Boxes 2']);
  });

  it('still writes a single sheet when no extra tab is asked for', () => {
    const wb = captured(() => exportToExcel('purchases', [{ Total: 1440 }], 'Purchases'));
    expect(wb.SheetNames).toEqual(['Purchases']);
  });
});
