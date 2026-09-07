import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { autoMap, buildRows, missingRequired, normalizeHeader, parseSpreadsheet } from './parse';
import { findTarget } from './targets';

const seed = (f: string) => readFileSync(new URL(`../../../../seed/${f}`, import.meta.url), 'utf8');

describe('importer parsing against the client seed files', () => {
  it('parses items.csv and auto-maps every column', () => {
    const parsed = parseSpreadsheet(seed('items.csv'), 'items.csv');
    const target = findTarget('items');
    if (!target) throw new Error('items target missing');
    expect(parsed.rows).toHaveLength(166);
    const map = autoMap(parsed.headers, target.fields);
    expect(missingRequired(map, target.fields)).toHaveLength(0);
    expect(map.item_code).toBeGreaterThanOrEqual(0);
    expect(map.pack_type).toBeGreaterThanOrEqual(0);
    expect(map.section_code).toBeGreaterThanOrEqual(0);
    const rows = buildRows(parsed, map);
    const laddu = rows.find((r) => r.item_code === '2');
    expect(laddu?.name).toBe('5/- BOONDI LADDU (12) 48');
    expect(laddu?.units_per_box).toBe('48');
    expect(laddu?.pieces_per_unit).toBe('12');
    // text codes stay text
    expect(rows.some((r) => r.item_code === '27A')).toBe(true);
  });

  it('parses opening_stock.csv with 237 rows including negatives', () => {
    const parsed = parseSpreadsheet(seed('opening_stock.csv'), 'opening_stock.csv');
    const target = findTarget('opening_stock');
    if (!target) throw new Error('target missing');
    expect(parsed.rows).toHaveLength(237);
    const map = autoMap(parsed.headers, target.fields);
    expect(missingRequired(map, target.fields)).toHaveLength(0);
    const rows = buildRows(parsed, map);
    expect(rows.filter((r) => Number(r.opening_boxes) < 0)).toHaveLength(7);
  });

  it('parses sections.csv (15) and unmatched_items.csv (85)', () => {
    expect(parseSpreadsheet(seed('sections.csv'), 's').rows).toHaveLength(15);
    expect(parseSpreadsheet(seed('unmatched_items.csv'), 'u').rows).toHaveLength(85);
  });

  it('maps the client’s own spreadsheet headers', () => {
    const target = findTarget('items');
    if (!target) throw new Error('target missing');
    const map = autoMap(['CODE', 'Pack', 'Group / Item Name', 'BOX'], target.fields);
    expect(map.item_code).toBe(0);
    expect(map.pack_type).toBe(1);
    expect(map.name).toBe(2);
    expect(map.units_per_box).toBe(3);
  });

  it('never maps one column to two fields', () => {
    const target = findTarget('customers');
    if (!target) throw new Error('target missing');
    const map = autoMap(['Name', 'Mobile'], target.fields);
    expect(map.name).toBe(0);
    expect(map.mobile1).toBe(1);
    expect(map.mobile2).toBe(-1);
  });

  it('normalises headers', () => {
    expect(normalizeHeader('Item Code')).toBe('itemcode');
    expect(normalizeHeader('Units / box')).toBe('unitsbox');
  });
});
