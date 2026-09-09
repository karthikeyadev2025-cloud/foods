import { describe, expect, it } from 'vitest';
import { orIlike, rankByCode, searchWords } from './search';

/** Records what would be sent, in the same shape PostgREST receives it. */
function fakeQuery() {
  const filters: string[] = [];
  const q = {
    or(filter: string) {
      filters.push(filter);
      return q;
    },
    filters,
  };
  return q;
}

describe('searchWords', () => {
  it('splits on whitespace and keeps punctuation', () => {
    expect(searchWords('boondi laddu (12)')).toEqual(['boondi', 'laddu', '(12)']);
  });

  it('is empty for nothing typed, so the search does not filter', () => {
    expect(searchWords(undefined)).toEqual([]);
    expect(searchWords('   ')).toEqual([]);
  });

  it('stops at six words — beyond that it is a paste, not a search', () => {
    expect(searchWords('a b c d e f g h')).toHaveLength(6);
  });
});

describe('orIlike', () => {
  it('does not filter at all when nothing is typed', () => {
    const q = fakeQuery();
    orIlike(q, ['item_code', 'name'], '');
    expect(q.filters).toEqual([]);
  });

  it('ORs across the columns for one word, and sends a plain word bare', () => {
    const q = fakeQuery();
    orIlike(q, ['item_code', 'name'], 'laddu');
    // Byte for byte what this app has always sent, so a plain search cannot regress.
    expect(q.filters).toEqual(['item_code.ilike.%laddu%,name.ilike.%laddu%']);
  });

  it('ANDs across words, so "laddu 48" finds "BOONDI LADDU (12) 48"', () => {
    const q = fakeQuery();
    orIlike(q, ['item_code', 'name'], 'laddu 48');
    expect(q.filters).toHaveLength(2);
    expect(q.filters[0]).toContain('%laddu%');
    expect(q.filters[1]).toContain('%48%');
  });

  /**
   * The bug this file exists for. The old helper deleted ( ) , and % from the
   * term to protect PostgREST's filter syntax, so searching this master's own
   * item names found nothing. Quoting protects the syntax and keeps the term.
   */
  it('keeps brackets, commas and dots that the item names actually contain', () => {
    const q = fakeQuery();
    orIlike(q, ['name'], 'PAK(12)');
    expect(q.filters[0]).toBe('name.ilike."%PAK(12)%"');   // quoted only because of the brackets
  });

  it('keeps the punctuation in a customer name like "P. SRINIVAS (MCL)"', () => {
    const q = fakeQuery();
    orIlike(q, ['name'], 'P. SRINIVAS (MCL)');
    expect(q.filters).toEqual([
      'name.ilike."%P.%"',          // the dot needs the quotes
      'name.ilike.%SRINIVAS%',      // this one does not, so it goes through bare
      'name.ilike."%(MCL)%"',
    ]);
  });

  it('escapes the two characters that could still break out of the quotes', () => {
    const q = fakeQuery();
    orIlike(q, ['name'], 'a"b\\c');
    expect(q.filters[0]).toBe('name.ilike."%a\\"b\\\\c%"');
  });
});

describe('rankByCode', () => {
  const rows = [
    { item_code: '120', name: 'KAJU BURFI' },
    { item_code: '48', name: 'BOONDI LADDU (12) 48' },
    { item_code: '12', name: 'HT. MYSOOR PAK(12) 32' },
    { item_code: '99', name: '12 O CLOCK MIXTURE' },
  ];

  it('puts the code typed in full first, ahead of names that merely contain it', () => {
    expect(rankByCode(rows, '12')[0]?.item_code).toBe('12');
  });

  it('then codes that start with it, then names that start with it', () => {
    const order = rankByCode(rows, '12').map((r) => r.item_code);
    expect(order).toEqual(['12', '120', '99', '48']);
  });

  it('leaves the order alone when nothing is typed', () => {
    expect(rankByCode(rows, '  ').map((r) => r.item_code)).toEqual(['120', '48', '12', '99']);
  });
});
