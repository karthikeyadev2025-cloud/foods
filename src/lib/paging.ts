/** Server-side pagination helpers (DOMAIN_RULES.md rule 6: no client-side filtering of full tables). */

export interface PageQuery {
  page: number;
  pageSize: number;
  search?: string;
}

export interface Page<T> {
  rows: T[];
  total: number;
  page: number;
  pageSize: number;
}

export const PAGE_SIZES = [25, 50, 100] as const;
export const DEFAULT_PAGE_SIZE = 50;

/** Inclusive PostgREST range for a 1-based page. */
export function rangeFor(page: number, pageSize: number): [number, number] {
  const from = Math.max(0, (page - 1) * pageSize);
  return [from, from + pageSize - 1];
}

/** Strip characters that would break a PostgREST `or(... ilike ...)` filter. */

export function pageCount(total: number, pageSize: number): number {
  return Math.max(1, Math.ceil(total / pageSize));
}
