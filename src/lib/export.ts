import * as XLSX from 'xlsx';

/**
 * Excel export for any list or report (DOMAIN_RULES.md rule 6). Pass plain row objects
 * with display-ready headers as keys; numbers stay numbers so Excel can sum them.
 */
export function exportToExcel(filename: string, rows: Record<string, unknown>[], sheetName = 'Sheet1'): void {
  const ws = XLSX.utils.json_to_sheet(rows);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, sheetName.slice(0, 31));
  XLSX.writeFile(wb, filename.endsWith('.xlsx') ? filename : `${filename}.xlsx`);
}
