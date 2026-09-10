import { describe, expect, it } from 'vitest';
import type { ImportErrorRow } from '../api';
import { groupProblems } from './problems';

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
