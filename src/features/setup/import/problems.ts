import type { ImportErrorRow } from '../api';

export interface Problem {
  /** The message the database gave, verbatim. */
  message: string;
  /** How many rows failed this way. */
  count: number;
  /** The first few row numbers, for finding them in the file. */
  rows: number[];
  /** True when `rows` is only the start of a longer list. */
  more: boolean;
}

const SHOWN = 8;

/**
 * Collapse the error rows into the distinct things that are actually wrong.
 *
 * A file whose pack type column says BOX produces one error per row. At 250
 * rows that is 250 identical lines and a scrollbar, which reads as 250
 * problems and is really one — and the second, different problem is somewhere
 * below the fold where nobody finds it until the next attempt fails too.
 *
 * Grouped on the message as the database wrote it, so each distinct bad VALUE
 * stays its own line: "BOX" and "TRY" are two problems, not one, because they
 * are two things to fix.
 */
export function groupProblems(errorRows: ImportErrorRow[]): Problem[] {
  const byMessage = new Map<string, Problem>();
  for (const e of errorRows) {
    const message = e.error || 'Unknown problem';
    const hit = byMessage.get(message);
    if (hit) {
      hit.count += 1;
      if (hit.rows.length < SHOWN) hit.rows.push(e.row);
      else hit.more = true;
    } else {
      byMessage.set(message, { message, count: 1, rows: [e.row], more: false });
    }
  }
  // Commonest first: the one blocking the most rows is the one to fix first.
  return [...byMessage.values()].sort((a, b) => b.count - a.count || a.message.localeCompare(b.message));
}

export interface ColumnSample {
  /** Up to a handful of the distinct values in this column. */
  values: string[];
  /** True when there are more distinct values than shown. */
  more: boolean;
  /** Every row carries the same value — nearly always a column matched to the wrong field. */
  constant: boolean;
  /** How many rows have nothing here at all. */
  blanks: number;
}

const SAMPLES = 4;

/**
 * What is really in a column, not just its first cell.
 *
 * The mapping step used to show one value, and one value cannot show you that
 * "Pieces per unit" reads 38 on every row of a file whose products are packed
 * 8, 48 and 21 to a box. That is a column matched to the wrong field, it is
 * obvious the moment three values are visible instead of one, and it decides
 * how many pieces come out of a box on every bill afterwards.
 */
export function sampleColumn(rows: string[][], index: number): ColumnSample {
  const distinct = new Set<string>();
  const values: string[] = [];
  let blanks = 0;
  for (const r of rows) {
    const v = (r[index] ?? '').trim();
    if (!v) {
      blanks += 1;
      continue;
    }
    if (distinct.has(v)) continue;
    distinct.add(v);
    if (values.length < SAMPLES) values.push(v);
  }
  return {
    values,
    more: distinct.size > values.length,
    // One value everywhere, and enough rows for that to mean something.
    constant: distinct.size === 1 && rows.length - blanks > 2,
    blanks,
  };
}
