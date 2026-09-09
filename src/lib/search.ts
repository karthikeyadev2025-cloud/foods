/**
 * Search boxes, everywhere in the ERP.
 *
 * Two things every one of them needs, and neither is optional in this master:
 *
 *   punctuation survives   The item names are "5/- HT. MYSOOR PAK(12) 32" and
 *                          the customers are "P. SRINIVAS (MCL)". The old
 *                          helper stripped ( ) , and % out of the term to keep
 *                          them from breaking PostgREST's filter syntax, so
 *                          typing the name people actually read off the screen
 *                          searched for "PAK 12" and found nothing. Quoting the
 *                          value protects the syntax without touching the term.
 *
 *   words in any order     Nobody types a contiguous substring. They type
 *                          "laddu 48", which never matched "BOONDI LADDU (12)
 *                          48" because of the "(12)" in between. Each word is
 *                          now required, in any order, in any of the columns.
 *
 * `%` and `_` still act as wildcards — quoting is about PostgREST's parser, not
 * about LIKE — which is a fair reading of what someone typing them wants.
 */

/** More words than this is a paste, not a search; the rest would only narrow to nothing. */
const MAX_WORDS = 6;

export function searchWords(input: string | undefined): string[] {
  return (input ?? '').trim().split(/\s+/).filter(Boolean).slice(0, MAX_WORDS);
}

/** The characters PostgREST reads as filter syntax rather than as part of a value. */
const RESERVED = /[,.:()"\\]/;

/**
 * A PostgREST filter value.
 *
 * A word with nothing reserved in it goes through bare, which is byte for byte
 * what this app has always sent and what the whole ERP's search is known to work
 * on. Only a word carrying punctuation takes the quoted form, where the parser
 * stops treating , . : ( and ) as syntax and just the quote and backslash need
 * escaping. Quoting everything would have been tidier, but it would have put
 * every working search in the app on a path that could not be tried against a
 * real PostgREST from here. This way a plain search cannot regress, and a
 * punctuated one can only get better than the nothing it returns today.
 */
function value(word: string): string {
  if (!RESERVED.test(word)) return `%${word}%`;
  return `"%${word.replace(/[\\"]/g, (c) => `\\${c}`)}%"`;
}

/**
 * Narrow `query` to rows where every word appears in at least one of `columns`.
 *
 * Chained .or() calls are ANDed by PostgREST, which is exactly the shape wanted:
 * OR across the columns, AND across the words.
 */
export function orIlike<Q extends { or(filter: string): Q }>(
  query: Q,
  columns: readonly string[],
  input: string | undefined,
): Q {
  let out = query;
  for (const word of searchWords(input)) {
    out = out.or(columns.map((c) => `${c}.ilike.${value(word)}`).join(","));
  }
  return out;
}

/**
 * Bill entry sorts its own matches: the code someone typed in full comes first,
 * then codes that start with it, then names that start with it. Without this a
 * search for "12" buries item 12 under every name containing "(12)".
 */
export function rankByCode<T extends { item_code?: string | null; name?: string | null }>(
  rows: T[],
  input: string,
): T[] {
  const term = input.trim().toLowerCase();
  if (!term) return rows;
  const rank = (r: T) => {
    const code = (r.item_code ?? '').toLowerCase();
    const name = (r.name ?? '').toLowerCase();
    if (code === term) return 0;
    if (code.startsWith(term)) return 1;
    if (name.startsWith(term)) return 2;
    return 3;
  };
  return [...rows].sort((a, b) => rank(a) - rank(b));
}
