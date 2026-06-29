// Pure helpers for the shared-grocery-list flow — record parsing, aisle
// grouping, plain-text rendering, and check/note field naming. Kept free
// of any I/O so they unit-test cleanly (test/grocery.test.js) and are
// shared by the /list/<id> page + the /api/list-check & /api/list-note
// write endpoints.
//
// A shared grocery list is one `GroceryListShare` CloudKit public record:
//   - listName  (String)  list name
//   - itemsJSON (String)  JSON array of items: [{name,quantity,unit,aisle}]
//                         (a String, not an Asset — lists are tiny + photoless,
//                         so the Worker reads them inline with no second fetch)
//   - check0..check39 (Int64)  per-item in-cart flag, indexed by array position
//   - note0..note39   (String) per-item substitution state: "out" | "sub:<text>"
// Older test/dev records used `title`, `payload`, `qty`, and item `order`;
// parsing keeps a fallback for those so old links don't render empty.
//
// Per-item scalar fields (rather than one JSON blob) so simultaneous
// check-offs from the app + the web don't clobber each other.

/** Max per-item indexed fields on the record (check0..39 / note0..39). */
export const MAX_ITEMS = 40;

/** Canonical store-walk order — mirrors the Swift `GroceryAisle.ordered`. */
export const AISLE_ORDER = [
  'Produce',
  'Deli',
  'Bakery',
  'Meat & Seafood',
  'Dairy & Eggs',
  'Frozen',
  'Breakfast & Cereal',
  'Canned & Jarred',
  'Condiments & Sauces',
  'Pasta, Rice & Grains',
  'Baking',
  'Spices',
  'Snacks',
  'International',
  'Beverages',
  'Pantry & Dry Goods',
  'Baby',
  'Health & Pharmacy',
  'Personal Care',
  'Household',
  'Pet',
  'Other',
];

export const AISLE_FALLBACK = 'Other';

const AISLE_INDEX = new Map(AISLE_ORDER.map((a, i) => [a.toLowerCase(), i]));

/** Field name for an item's in-cart check flag. */
export function checkFieldName(index) {
  return `check${index}`;
}

/** Field name for an item's substitution note. */
export function noteFieldName(index) {
  return `note${index}`;
}

/** Normalize an arbitrary aisle string to one of AISLE_ORDER (unknown → Other). */
export function normalizeAisle(raw) {
  if (raw == null) return AISLE_FALLBACK;
  const key = String(raw).trim().toLowerCase();
  if (!key) return AISLE_FALLBACK;
  const i = AISLE_INDEX.get(key);
  return i == null ? AISLE_FALLBACK : AISLE_ORDER[i];
}

/**
 * Parse a fetched `GroceryListShare` record into a plain object the page
 * and endpoints can use. Defensive about missing fields and a malformed
 * payload (returns an empty item list rather than throwing).
 *
 * @returns {{title:string, items:Array<{name,quantity,unit,aisle,order,checked,note,outOfStock,substitution}>}}
 */
export function parseGroceryRecord(record) {
  const fields = record?.fields || {};
  const title = (fields.listName?.value ?? fields.title?.value ?? '').toString() || 'Grocery List';

  let raw = [];
  let usesArraySlots = true;
  try {
    const payload = fields.itemsJSON?.value ?? fields.payload?.value;
    usesArraySlots = fields.itemsJSON?.value != null;
    if (typeof payload === 'string' && payload.length) {
      const decoded = JSON.parse(payload);
      if (Array.isArray(decoded)) raw = decoded;
    }
  } catch {
    raw = [];
  }

  const items = raw.slice(0, MAX_ITEMS).map((it, i) => {
    // Current records use array position as the live check/note slot.
    // Legacy `payload` records may include `order`; clamp it so a malicious
    // value falls back to the array index rather than reaching past check0..39.
    const claimed = usesArraySlots ? i : (Number.isInteger(it?.order) ? it.order : i);
    const order = (claimed >= 0 && claimed < MAX_ITEMS) ? claimed : i;
    const checkVal = fields[checkFieldName(order)]?.value;
    const note = (fields[noteFieldName(order)]?.value ?? '').toString();
    return {
      name: (it?.name ?? '').toString(),
      quantity: it?.quantity != null ? String(it.quantity) : (it?.qty != null ? String(it.qty) : ''),
      unit: it?.unit != null ? String(it.unit) : '',
      aisle: normalizeAisle(it?.aisle),
      order,
      checked: checkVal === 1 || checkVal === true,
      note,
      outOfStock: note === 'out',
      substitution: note.startsWith('sub:') ? note.slice(4) : '',
    };
  });

  return { title, items };
}

/**
 * Group parsed items into `{ aisle, items }` sections in store-walk order.
 * Items keep their `order` within a section; empty sections are omitted.
 */
export function groupByAisle(items) {
  const buckets = new Map();
  for (const item of items) {
    const aisle = normalizeAisle(item.aisle);
    if (!buckets.has(aisle)) buckets.set(aisle, []);
    buckets.get(aisle).push(item);
  }
  const sections = [];
  for (const aisle of AISLE_ORDER) {
    const bucket = buckets.get(aisle);
    if (bucket && bucket.length) {
      bucket.sort((a, b) => a.order - b.order);
      sections.push({ aisle, items: bucket });
    }
  }
  return sections;
}

/** One item's measure — "2 cups", "3", or "" (joins quantity + unit). */
export function measureText(item) {
  return [item.quantity, item.unit].filter((s) => s && s.length).join(' ').trim();
}

/**
 * One item's full display line — "2 cups flour" / "milk" (+ swap note).
 *
 * SECURITY: output is TEXT ONLY and interpolates fully user-controlled
 * fields (`item.name`, `item.substitution`). Any future HTML renderer of
 * the shared `/list/<id>` page MUST run this through `escapeHTML` (reuse
 * the one in `functions/r/[id].js`) AND screen names via `lib/moderation.js`
 * — the CloudKit public DB is world-writable, so these bytes are untrusted.
 */
export function itemLine(item) {
  const measure = measureText(item);
  const base = measure ? `${measure} ${item.name}` : item.name;
  if (item.substitution) return `${base} → ${item.substitution}`;
  if (item.outOfStock) return `${base} (out of stock)`;
  return base;
}

/**
 * Plain-text rendering of a parsed list, grouped by aisle, for the web
 * page's "copy as text" affordance. Checked items are prefixed with [x],
 * unchecked items with [ ].
 */
export function formatPlainText({ title, items }) {
  const sections = groupByAisle(items);
  const lines = [title, ''];
  for (const section of sections) {
    if (sections.length > 1) lines.push(section.aisle.toUpperCase());
    for (const item of section.items) {
      lines.push(`${item.checked ? '[x]' : '[ ]'} ${itemLine(item)}`);
    }
    lines.push('');
  }
  return lines.join('\n').trim() + '\n';
}
