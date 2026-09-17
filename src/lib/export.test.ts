import { describe, expect, it } from 'vitest';
import { fileName, sheetName } from './export';

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
