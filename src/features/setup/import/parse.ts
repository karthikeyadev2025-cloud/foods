import * as XLSX from 'xlsx';
import type { ImportField } from './targets';

export interface ParsedFile {
  name: string;
  headers: string[];
  rows: string[][];
}

/** Read the first sheet of an XLSX/XLS/CSV. Cells come back as display strings so "27 A" stays text. */
export function parseSpreadsheet(data: ArrayBuffer | string, name: string): ParsedFile {
  const wb = XLSX.read(data, { type: typeof data === 'string' ? 'string' : 'array', raw: false });
  const first = wb.SheetNames[0];
  const ws = first ? wb.Sheets[first] : undefined;
  if (!ws) return { name, headers: [], rows: [] };
  const grid = XLSX.utils.sheet_to_json<unknown[]>(ws, { header: 1, raw: false, defval: '', blankrows: false });
  const toText = (v: unknown) => (v === null || v === undefined ? '' : String(v).trim());
  const [head = [], ...body] = grid;
  const headers = head.map(toText);
  const rows = body
    .map((r) => headers.map((_, i) => toText(r[i])))
    .filter((r) => r.some((c) => c !== ''));
  return { name, headers, rows };
}

/** "Item Code" → "itemcode", "Units / box" → "unitsbox" */
export function normalizeHeader(h: string): string {
  return h.toLowerCase().replace(/[^a-z0-9]/g, '');
}

/** field key → column index in the file, or -1 when nothing matched. */
export type ColumnMap = Record<string, number>;

/** Best-effort mapping by exact key, label, or alias. Ambiguous headers map to the first field that claims them. */
export function autoMap(headers: string[], fields: ImportField[]): ColumnMap {
  const norm = headers.map(normalizeHeader);
  const taken = new Set<number>();
  const map: ColumnMap = {};
  for (const f of fields) {
    const candidates = [f.key, f.label, ...(f.aliases ?? [])].map(normalizeHeader);
    let idx = -1;
    for (const c of candidates) {
      const i = norm.findIndex((h, hi) => h === c && !taken.has(hi));
      if (i >= 0) {
        idx = i;
        break;
      }
    }
    map[f.key] = idx;
    if (idx >= 0) taken.add(idx);
  }
  return map;
}

/** Apply the mapping: one object per file row, keyed by target field. Unmapped fields are omitted. */
export function buildRows(parsed: ParsedFile, map: ColumnMap): Record<string, string>[] {
  const entries = Object.entries(map).filter(([, i]) => i >= 0);
  return parsed.rows.map((r) => {
    const out: Record<string, string> = {};
    for (const [key, i] of entries) out[key] = r[i] ?? '';
    return out;
  });
}

/** Which required fields are still unmapped. */
export function missingRequired(map: ColumnMap, fields: ImportField[]): ImportField[] {
  return fields.filter((f) => f.required && (map[f.key] ?? -1) < 0);
}
