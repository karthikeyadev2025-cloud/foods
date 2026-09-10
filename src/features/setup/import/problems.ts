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
