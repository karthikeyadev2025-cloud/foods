export type ImportTargetKey = 'sections' | 'items' | 'customers' | 'opening_stock' | 'rates' | 'recipes';

export interface ImportField {
  key: string;
  label: string;
  required?: boolean;
  hint?: string;
  /** Extra header spellings that auto-map to this field (normalised: lowercase, alphanumerics only). */
  aliases?: string[];
}

export interface BundledFile {
  label: string;
  /** Served from public/seed — the client's own data, decoded from their spreadsheets. */
  path: string;
  note?: string;
}

export interface ImportTarget {
  key: ImportTargetKey;
  label: string;
  description: string;
  fields: ImportField[];
  needsLocation?: boolean;
  /** Has fields that must match a Setup list — so the file may name one that does not exist yet. */
  hasLookups?: boolean;
  bundled?: BundledFile[];
}

/** Mirrors db/07_import.sql: the field names each target reads from every row. */
export const IMPORT_TARGETS: ImportTarget[] = [
  {
    key: 'sections',
    label: 'Sections (mestri groups)',
    description: 'Matched by name. Sets the code and the order they print on the stock report.',
    fields: [
      { key: 'name', label: 'Section name', required: true, aliases: ['section', 'sectionname', 'group'] },
      { key: 'code', label: 'Code', hint: 'S-10 etc. Leave blank for OTHERS / R.K.BAKERY', aliases: ['sectioncode'] },
      { key: 'sort_order', label: 'Sort order', aliases: ['order', 'sortorder', 'sno'] },
    ],
    bundled: [{ label: "Jyothi Foods sections (from STOCK_REPORT.xlsx)", path: '/seed/sections.csv' }],
  },
  {
    key: 'items',
    label: 'Items',
    description:
      'Matched by item code (text: 27A, 06A…). Packing is required and never assumed to be 8. Pack type and section must already exist in Setup, unless you ask for them to be created.',
    hasLookups: true,
    fields: [
      { key: 'item_code', label: 'Item code', required: true, aliases: ['code', 'itemcode', 'itemno'] },
      { key: 'name', label: 'Item name', required: true, aliases: ['itemname', 'groupitemname', 'description'] },
      { key: 'units_per_box', label: 'Units per box', required: true, hint: 'jars / packs / L.B per box', aliases: ['unitsperbox', 'box', 'jars', 'jarsperbox', 'perbox'] },
      { key: 'pieces_per_unit', label: 'Pieces per unit', hint: 'the "(12)" in the name; defaults to 1', aliases: ['piecesperunit', 'pieces', 'pcs'] },
      { key: 'pack_type', label: 'Pack type', hint: 'JAR / PACK / L.B / KG / TRY', aliases: ['pack', 'packtype'] },
      { key: 'section_code', label: 'Section', hint: 'code (S-10) or name', aliases: ['section', 'sectioncode', 'sectionname', 'group'] },
      { key: 'mrp_per_piece', label: 'MRP per piece', aliases: ['mrp', 'mrpperpiece'] },
      { key: 'unit_rate', label: 'Unit rate', hint: 'per jar / pack, not per box', aliases: ['rate', 'unitrate', 'price'] },
      { key: 'purchase_rate', label: 'Purchase rate', aliases: ['purchaserate', 'cost'] },
      { key: 'reorder_level', label: 'Reorder level', aliases: ['reorderlevel', 'minstock'] },
      { key: 'shelf_life_days', label: 'Shelf life (days)', aliases: ['shelflife', 'shelflifedays'] },
    ],
    bundled: [
      { label: 'Price list items (166)', path: '/seed/items.csv', note: 'From Structured_Item_Price_List.xlsx. Rates are blank until the client supplies them.' },
      {
        label: 'Stock-report-only items (85)',
        path: '/seed/unmatched_items.csv',
        note: 'Codes in STOCK_REPORT.xlsx that are not on the price list. Only the ones whose name encodes the packing will load; the rest come back as error rows for you to fill in.',
      },
    ],
  },
  {
    key: 'customers',
    label: 'Customers',
    description: 'Matched by mobile 1, so re-importing the same file never duplicates. Unknown routes are created.',
    fields: [
      { key: 'name', label: 'Name / company', required: true, aliases: ['customer', 'customername', 'company', 'companyname', 'party'] },
      { key: 'mobile1', label: 'Mobile 1', required: true, aliases: ['mobile', 'phone', 'mobileno', 'mobile1', 'phone1', 'contact'] },
      { key: 'mobile2', label: 'Mobile 2', aliases: ['phone2', 'altmobile'] },
      { key: 'mobile3', label: 'Mobile 3', aliases: ['phone3'] },
      { key: 'town', label: 'City / town', aliases: ['city', 'place', 'village'] },
      { key: 'address', label: 'Address' },
      { key: 'route', label: 'Route', aliases: ['routename', 'line'] },
      { key: 'code', label: 'Ledger code', aliases: ['customercode', 'sno', 'ledgercode'] },
      { key: 'price_group', label: 'Price group', aliases: ['pricegroup', 'group'] },
      { key: 'credit_limit', label: 'Credit limit', aliases: ['creditlimit', 'limit'] },
      { key: 'opening_balance', label: 'Opening balance', hint: 'positive = customer owes', aliases: ['openingbalance', 'opening', 'balance', 'outstanding'] },
      { key: 'whatsapp_opt_in', label: 'WhatsApp opt-in', hint: 'yes / no, defaults to yes', aliases: ['whatsapp', 'optin'] },
    ],
  },
  {
    key: 'opening_stock',
    label: 'Opening stock',
    description:
      'Boxes per item, converted with each item’s own units per box, posted as opening rows at the chosen location and date. Re-importing the same figures does nothing; a changed figure posts an adjustment.',
    needsLocation: true,
    fields: [
      { key: 'item_code', label: 'Item code', required: true, aliases: ['code', 'itemcode'] },
      { key: 'opening_boxes', label: 'Opening (boxes)', required: true, aliases: ['opening', 'boxes', 'qty', 'quantity', 'closing', 'stock'] },
    ],
    bundled: [{ label: 'Opening stock as on 06-09-2026 (237 rows)', path: '/seed/opening_stock.csv', note: 'From STOCK_REPORT.xlsx, including the 7 negative rows.' }],
  },
  {
    /*
      The only target whose rows are not records. A recipe is a product and
      everything that goes into it, so the sheet holds one row per INGREDIENT
      with the product code repeated, and every row naming the same product
      becomes one recipe — wherever those rows sit in the file.
    */
    key: 'recipes',
    label: 'Recipes (production)',
    description:
      'One row per ingredient, repeating the product code. Rows naming the same product become one recipe and replace whatever that product had before. Both the product and the ingredients must already be in the item master.',
    fields: [
      { key: 'item_code', label: 'Product code', required: true, hint: 'the finished good this recipe makes', aliases: ['code', 'itemcode', 'productcode', 'product', 'finishedgood'] },
      { key: 'pieces_per_plate', label: 'Pieces per plate', required: true, hint: 'write it once, on the first line of each recipe', aliases: ['piecesperplate', 'plate', 'platesize', 'output', 'outputpieces'] },
      { key: 'ingredient_code', label: 'Ingredient code', required: true, hint: 'a raw or packing material, not a finished good', aliases: ['ingredient', 'ingredientcode', 'rawcode', 'rawmaterial', 'material'] },
      { key: 'qty_per_plate', label: 'Qty per plate', required: true, aliases: ['qty', 'quantity', 'qtyperplate', 'usage'] },
      { key: 'uom', label: 'Unit', hint: 'KG, G, L… defaults to the ingredient’s own unit', aliases: ['unit', 'uomcode', 'units'] },
      { key: 'name', label: 'Recipe name', hint: 'optional; defaults to the product name', aliases: ['recipename', 'recipe'] },
    ],
  },
  {
    key: 'rates',
    label: 'Rates',
    description: 'Updates unit rate and/or purchase rate on existing items. Unknown codes are reported, nothing is created.',
    fields: [
      { key: 'item_code', label: 'Item code', required: true, aliases: ['code', 'itemcode'] },
      { key: 'unit_rate', label: 'Unit rate', hint: 'per jar / pack, not per box', aliases: ['rate', 'unitrate', 'price', 'sellingrate'] },
      { key: 'purchase_rate', label: 'Purchase rate', aliases: ['purchaserate', 'cost', 'costrate'] },
    ],
  },
];

export function findTarget(key: string | null | undefined): ImportTarget | undefined {
  return IMPORT_TARGETS.find((t) => t.key === key);
}
