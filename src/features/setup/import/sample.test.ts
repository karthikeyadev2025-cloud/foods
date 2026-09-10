import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { autoMap, missingRequired, parseSpreadsheet } from './parse';
import { IMPORT_TARGETS, findTarget } from './targets';

/**
 * The sample workbook has to survive the app's own parser and column matcher,
 * not merely look right in Excel. A sample that needs hand-mapping teaches the
 * person that the import is fiddly, which is the opposite of its job.
 *
 * Built by scripts/make-sample-import.mjs; this reads the committed file, so if
 * a target gains a required field and the sample is not regenerated, this fails.
 */
const FILE = 'public/seed/sample-import.xlsx';
const book = () => readFileSync(FILE).buffer.slice(0) as ArrayBuffer;

/** Sheet name in the workbook → the import target it is meant for. */
const SHEET_FOR_TARGET: Record<string, string> = {
  sections: 'Sections',
  items: 'Items',
  customers: 'Customers',
  opening_stock: 'Opening stock',
  rates: 'Rates',
};

describe('the sample import workbook', () => {
  it('has a sheet for every target the screen offers', () => {
    const { sheets } = parseSpreadsheet(book(), 'sample-import.xlsx');
    for (const t of IMPORT_TARGETS) {
      expect(SHEET_FOR_TARGET[t.key], `no sample sheet planned for target ${t.key}`).toBeTruthy();
      expect(sheets).toContain(SHEET_FOR_TARGET[t.key]);
    }
    // And nothing extra, or the person is left wondering what the spare is for.
    expect(sheets.sort()).toEqual(Object.values(SHEET_FOR_TARGET).sort());
  });

  it.each(IMPORT_TARGETS.map((t) => [t.key] as const))(
    'maps every required column of %s with no hand-mapping',
    (key) => {
      const target = findTarget(key)!;
      const parsed = parseSpreadsheet(book(), 'sample-import.xlsx', SHEET_FOR_TARGET[key]);
      expect(parsed.sheet).toBe(SHEET_FOR_TARGET[key]);
      expect(parsed.rows.length).toBeGreaterThan(0);

      const map = autoMap(parsed.headers, target.fields);
      expect(missingRequired(map, target.fields).map((f) => f.label)).toEqual([]);

      // Not only the required ones: every column in the sheet should belong to
      // a field, or the sample is showing a column the import will ignore.
      const claimed = new Set(Object.values(map).filter((i) => i >= 0));
      const orphans = parsed.headers.filter((_, i) => !claimed.has(i));
      expect(orphans, `columns nothing maps to in ${key}`).toEqual([]);
    },
  );

  it('reads the sheet asked for, not always the first', () => {
    const first = parseSpreadsheet(book(), 'x.xlsx');
    const rates = parseSpreadsheet(book(), 'x.xlsx', 'Rates');
    expect(first.sheet).not.toBe('Rates');
    expect(rates.sheet).toBe('Rates');
    expect(rates.headers[0]).toBe('Item code');
  });

  it('falls back to the first sheet when asked for one that is not there', () => {
    const p = parseSpreadsheet(book(), 'x.xlsx', 'No Such Sheet');
    expect(p.sheet).toBe('Sections');
    expect(p.rows.length).toBeGreaterThan(0);
  });

  it('keeps a text item code as text, so 27A does not become a number', () => {
    const items = parseSpreadsheet(book(), 'x.xlsx', 'Items');
    const codes = items.rows.map((r) => r[0]);
    expect(codes).toContain('27A');
  });

  it('carries a negative opening stock, because the real data has them', () => {
    const stock = parseSpreadsheet(book(), 'x.xlsx', 'Opening stock');
    expect(stock.rows.some((r) => (r[1] ?? '').startsWith('-'))).toBe(true);
  });
});
