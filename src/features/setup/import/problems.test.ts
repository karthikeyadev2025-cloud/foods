import { describe, expect, it } from 'vitest';
import type { ImportErrorRow } from '../api';
import { groupProblems, sampleColumn } from './problems';

const row = (n: number, error: string): ImportErrorRow => ({ row: n, error, data: {} });

describe('groupProblems', () => {
  it('turns 250 identical errors into one line', () => {
    const rows = Array.from({ length: 250 }, (_, i) => row(i + 1, 'Unknown pack type "BOX"'));
    const found = groupProblems(rows);
    expect(found).toHaveLength(1);
    expect(found[0]).toMatchObject({
      message: 'Unknown pack type "BOX"',
      count: 250,
      more: true,
    });
    expect(found[0]?.rows).toHaveLength(8);
  });

  it('keeps a different bad value as its own problem', () => {
    const rows = [
      ...Array.from({ length: 5 }, (_, i) => row(i + 1, 'Unknown pack type "BOX"')),
      row(6, 'Unknown pack type "TRY"'),
    ];
    expect(groupProblems(rows).map((p) => [p.message, p.count])).toEqual([
      ['Unknown pack type "BOX"', 5],
      ['Unknown pack type "TRY"', 1],
    ]);
  });

  it('puts the problem blocking the most rows first', () => {
    const rows = [
      row(1, 'name is required'),
      ...Array.from({ length: 3 }, (_, i) => row(i + 2, 'Unknown section "RAMA KRISHANA"')),
    ];
    expect(groupProblems(rows)[0]?.message).toBe('Unknown section "RAMA KRISHANA"');
  });

  it('does not claim there are more rows when every one is listed', () => {
    expect(groupProblems([row(4, 'x'), row(9, 'x')])[0]).toMatchObject({ rows: [4, 9], more: false });
  });

  it('gives a blank message somewhere to live rather than dropping the row', () => {
    expect(groupProblems([row(1, '')])).toEqual([
      { message: 'Unknown problem', count: 1, rows: [1], more: false },
    ]);
  });

  it('returns nothing for no errors', () => {
    expect(groupProblems([])).toEqual([]);
  });
});

describe('sampleColumn', () => {
  // The real shape of the file that failed: packing varies down the column,
  // pieces-per-unit does not.
  const rows = [
    ['1', '8', '38'],
    ['2', '48', '38'],
    ['3', '21', '38'],
    ['4', '8', '38'],
  ];

  it('flags the column that reads the same on every row', () => {
    const s = sampleColumn(rows, 2);
    expect(s.constant).toBe(true);
    expect(s.values).toEqual(['38']);
  });

  it('does not flag a column that actually varies', () => {
    const s = sampleColumn(rows, 1);
    expect(s.constant).toBe(false);
    expect(s.values).toEqual(['8', '48', '21']);
  });

  it('shows a handful of distinct values and says there are more', () => {
    const many = Array.from({ length: 30 }, (_, i) => [String(i)]);
    const s = sampleColumn(many, 0);
    expect(s.values).toEqual(['0', '1', '2', '3']);
    expect(s.more).toBe(true);
  });

  it('counts blanks and does not treat them as a value', () => {
    const s = sampleColumn([['a'], [''], ['  '], ['a']], 0);
    expect(s.values).toEqual(['a']);
    expect(s.blanks).toBe(2);
  });

  it('calls nothing constant on a file too short to judge', () => {
    // Two identical rows is a coincidence, not a pattern worth a warning.
    expect(sampleColumn([['5'], ['5']], 0).constant).toBe(false);
    expect(sampleColumn([['5'], ['5'], ['5']], 0).constant).toBe(true);
  });

  it('survives a ragged row that is shorter than the header', () => {
    const s = sampleColumn([['a', 'b'], ['c']], 1);
    expect(s.values).toEqual(['b']);
    expect(s.blanks).toBe(1);
  });

  it('reports an entirely empty column rather than pretending it has values', () => {
    expect(sampleColumn([[''], ['']], 0)).toMatchObject({ values: [], blanks: 2, constant: false });
  });
});
