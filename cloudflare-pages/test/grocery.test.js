import { describe, it, expect } from 'vitest';
import {
  MAX_ITEMS,
  AISLE_ORDER,
  AISLE_FALLBACK,
  checkFieldName,
  noteFieldName,
  normalizeAisle,
  parseGroceryRecord,
  groupByAisle,
  measureText,
  itemLine,
  formatPlainText,
} from '../lib/grocery.js';

// Build a CloudKit-shaped record from a compact spec.
function makeRecord(title, items, overrides = {}) {
  const fields = {
    listName: { value: title },
    itemsJSON: { value: JSON.stringify(items) },
    ...overrides,
  };
  return { fields };
}

// ── Constants ───────────────────────────────────────────────────────────────

describe('grocery constants', () => {
  it('MAX_ITEMS is 40 (matches check0..39 / note0..39)', () => {
    expect(MAX_ITEMS).toBe(40);
  });
  it('AISLE_ORDER starts at Produce and ends at Other', () => {
    expect(AISLE_ORDER[0]).toBe('Produce');
    expect(AISLE_ORDER[AISLE_ORDER.length - 1]).toBe('Other');
  });
  it('AISLE_FALLBACK is in AISLE_ORDER', () => {
    expect(AISLE_ORDER).toContain(AISLE_FALLBACK);
  });
  it('has the full 22-department store-walk taxonomy', () => {
    expect(AISLE_ORDER).toHaveLength(22);
  });
  it('includes the new center-store departments', () => {
    for (const aisle of [
      'Deli', 'Breakfast & Cereal', 'Canned & Jarred', 'Condiments & Sauces',
      'Pasta, Rice & Grains', 'Baking', 'Snacks', 'International',
    ]) {
      expect(AISLE_ORDER).toContain(aisle);
    }
  });
  it('keeps the backward-compat Pantry & Dry Goods bucket', () => {
    expect(AISLE_ORDER).toContain('Pantry & Dry Goods');
  });
  it('includes the non-food departments after Beverages and before Other', () => {
    for (const aisle of ['Baby', 'Health & Pharmacy', 'Personal Care', 'Pet']) {
      expect(AISLE_ORDER).toContain(aisle);
    }
    expect(AISLE_ORDER.indexOf('Health & Pharmacy')).toBeGreaterThan(AISLE_ORDER.indexOf('Beverages'));
    expect(AISLE_ORDER.indexOf('Pet')).toBeLessThan(AISLE_ORDER.indexOf('Other'));
  });
  it('orders the new perimeter/center aisles correctly', () => {
    // Deli sits right after Produce; the dry center aisles precede Beverages.
    expect(AISLE_ORDER.indexOf('Deli')).toBe(AISLE_ORDER.indexOf('Produce') + 1);
    expect(AISLE_ORDER.indexOf('Baking')).toBeGreaterThan(AISLE_ORDER.indexOf('Canned & Jarred'));
    expect(AISLE_ORDER.indexOf('International')).toBeLessThan(AISLE_ORDER.indexOf('Beverages'));
  });
  it('field names are check<N> / note<N>', () => {
    expect(checkFieldName(0)).toBe('check0');
    expect(checkFieldName(39)).toBe('check39');
    expect(noteFieldName(7)).toBe('note7');
  });
});

// ── normalizeAisle ──────────────────────────────────────────────────────────

describe('normalizeAisle', () => {
  it('passes through a canonical aisle', () => {
    expect(normalizeAisle('Produce')).toBe('Produce');
  });
  it('is case- and whitespace-insensitive', () => {
    expect(normalizeAisle('  dairy & eggs ')).toBe('Dairy & Eggs');
    expect(normalizeAisle('health & pharmacy')).toBe('Health & Pharmacy');
    expect(normalizeAisle(' Personal Care ')).toBe('Personal Care');
  });
  it('passes through the new center-store departments', () => {
    expect(normalizeAisle('canned & jarred')).toBe('Canned & Jarred');
    expect(normalizeAisle('  condiments & sauces')).toBe('Condiments & Sauces');
    expect(normalizeAisle('pasta, rice & grains')).toBe('Pasta, Rice & Grains');
    expect(normalizeAisle('INTERNATIONAL')).toBe('International');
    expect(normalizeAisle('Deli')).toBe('Deli');
  });
  it('maps unknown / empty / null to Other', () => {
    expect(normalizeAisle('Garden Center')).toBe('Other');
    expect(normalizeAisle('')).toBe('Other');
    expect(normalizeAisle(null)).toBe('Other');
    expect(normalizeAisle(undefined)).toBe('Other');
  });
});

// ── parseGroceryRecord ──────────────────────────────────────────────────────

describe('parseGroceryRecord', () => {
  it('parses title + items with measures and aisles', () => {
    const record = makeRecord('Taco Night', [
      { name: 'Tomatoes', quantity: '3', unit: '', aisle: 'Produce' },
      { name: 'Ground beef', quantity: '1', unit: 'lb', aisle: 'Meat & Seafood' },
    ]);
    const parsed = parseGroceryRecord(record);
    expect(parsed.title).toBe('Taco Night');
    expect(parsed.items).toHaveLength(2);
    expect(parsed.items[0]).toMatchObject({ name: 'Tomatoes', quantity: '3', aisle: 'Produce', checked: false });
    expect(parsed.items[1]).toMatchObject({ name: 'Ground beef', unit: 'lb', aisle: 'Meat & Seafood' });
  });

  it('reads per-item check flags by array slot', () => {
    const record = makeRecord('List', [
      { name: 'Milk', aisle: 'Dairy & Eggs' },
      { name: 'Eggs', aisle: 'Dairy & Eggs' },
    ], {
      check0: { value: 1 },
      // check1 absent → unchecked
    });
    const parsed = parseGroceryRecord(record);
    expect(parsed.items[0].checked).toBe(true);
    expect(parsed.items[1].checked).toBe(false);
  });

  it('decodes note fields into outOfStock / substitution', () => {
    const record = makeRecord('List', [
      { name: 'White eggs', aisle: 'Dairy & Eggs' },
      { name: 'Butter', aisle: 'Dairy & Eggs' },
    ], {
      note0: { value: 'out' },
      note1: { value: 'sub:margarine' },
    });
    const parsed = parseGroceryRecord(record);
    expect(parsed.items[0].outOfStock).toBe(true);
    expect(parsed.items[0].substitution).toBe('');
    expect(parsed.items[1].outOfStock).toBe(false);
    expect(parsed.items[1].substitution).toBe('margarine');
  });

  it('is defensive about a malformed payload', () => {
    const record = { fields: { listName: { value: 'Broken' }, itemsJSON: { value: '{not json' } } };
    const parsed = parseGroceryRecord(record);
    expect(parsed.title).toBe('Broken');
    expect(parsed.items).toEqual([]);
  });

  it('keeps legacy title/payload/qty/order records readable', () => {
    const record = {
      fields: {
        title: { value: 'Legacy' },
        payload: { value: JSON.stringify([{ name: 'Milk', qty: '1', unit: 'gal', aisle: 'Dairy & Eggs', order: 2 }]) },
        check2: { value: 1 },
      },
    };
    const parsed = parseGroceryRecord(record);
    expect(parsed.title).toBe('Legacy');
    expect(parsed.items[0]).toMatchObject({
      name: 'Milk',
      quantity: '1',
      unit: 'gal',
      aisle: 'Dairy & Eggs',
      order: 2,
      checked: true,
    });
  });

  it('falls back to a default title and empty items for an empty record', () => {
    const parsed = parseGroceryRecord({ fields: {} });
    expect(parsed.title).toBe('Grocery List');
    expect(parsed.items).toEqual([]);
  });

  it('caps at MAX_ITEMS', () => {
    const many = Array.from({ length: 50 }, (_, i) => ({ name: `Item ${i}` }));
    const parsed = parseGroceryRecord(makeRecord('Big', many));
    expect(parsed.items).toHaveLength(MAX_ITEMS);
  });
});

// ── groupByAisle ────────────────────────────────────────────────────────────

describe('groupByAisle', () => {
  it('orders sections by store-walk order and omits empty aisles', () => {
    const items = [
      { name: 'Milk', aisle: 'Dairy & Eggs', order: 0 },
      { name: 'Apples', aisle: 'Produce', order: 1 },
      { name: 'Bread', aisle: 'Bakery', order: 2 },
    ];
    const sections = groupByAisle(items);
    expect(sections.map((s) => s.aisle)).toEqual(['Produce', 'Bakery', 'Dairy & Eggs']);
  });

  it('keeps items sorted by order within a section', () => {
    const items = [
      { name: 'Spinach', aisle: 'Produce', order: 5 },
      { name: 'Apples', aisle: 'Produce', order: 1 },
    ];
    const [produce] = groupByAisle(items);
    expect(produce.items.map((i) => i.name)).toEqual(['Apples', 'Spinach']);
  });

  it('buckets unknown aisles under Other', () => {
    const sections = groupByAisle([{ name: 'Batteries', aisle: 'Hardware', order: 0 }]);
    expect(sections).toHaveLength(1);
    expect(sections[0].aisle).toBe('Other');
  });

  it('orders the new center-store departments by store-walk', () => {
    const items = [
      { name: 'Soy sauce', aisle: 'Condiments & Sauces', order: 0 },
      { name: 'Spaghetti', aisle: 'Pasta, Rice & Grains', order: 1 },
      { name: 'Flour', aisle: 'Baking', order: 2 },
      { name: 'Black beans (canned)', aisle: 'Canned & Jarred', order: 3 },
      { name: 'Tortilla chips', aisle: 'Snacks', order: 4 },
      { name: 'Sliced turkey', aisle: 'Deli', order: 5 },
    ];
    const sections = groupByAisle(items);
    expect(sections.map((s) => s.aisle)).toEqual([
      'Deli', 'Canned & Jarred', 'Condiments & Sauces', 'Pasta, Rice & Grains', 'Baking', 'Snacks',
    ]);
  });
});

// ── measureText / itemLine ──────────────────────────────────────────────────

describe('measureText / itemLine', () => {
  it('joins quantity + unit', () => {
    expect(measureText({ quantity: '2', unit: 'cups' })).toBe('2 cups');
    expect(measureText({ quantity: '3', unit: '' })).toBe('3');
    expect(measureText({ quantity: '', unit: '' })).toBe('');
  });
  it('builds a full line with measure + name', () => {
    expect(itemLine({ quantity: '2', unit: 'cups', name: 'flour' })).toBe('2 cups flour');
    expect(itemLine({ quantity: '', unit: '', name: 'milk' })).toBe('milk');
  });
  it('annotates substitution and out-of-stock', () => {
    expect(itemLine({ name: 'white eggs', substitution: 'brown eggs' })).toBe('white eggs → brown eggs');
    expect(itemLine({ name: 'shallots', outOfStock: true })).toBe('shallots (out of stock)');
  });
});

// ── formatPlainText ─────────────────────────────────────────────────────────

describe('formatPlainText', () => {
  it('renders aisle headers and check boxes for every item', () => {
    const parsed = {
      title: 'Weekend Shop',
      items: [
        { name: 'Apples', quantity: '6', unit: '', aisle: 'Produce', checked: false, order: 0 },
        { name: 'Milk', quantity: '1', unit: 'gal', aisle: 'Dairy & Eggs', checked: true, order: 1 },
        { name: 'Salt', quantity: '', unit: '', aisle: 'Spices', checked: false, order: 2 },
      ],
    };
    const text = formatPlainText(parsed);
    expect(text).toContain('Weekend Shop');
    expect(text).toContain('PRODUCE');
    expect(text).toContain('[ ] 6 Apples');
    expect(text).toContain('[x] 1 gal Milk');
    // Every item appears now that have/need filtering is gone.
    expect(text).toContain('[ ] Salt');
  });

  it('omits aisle headers when everything is one aisle', () => {
    const parsed = {
      title: 'Quick',
      items: [{ name: 'Milk', quantity: '', unit: '', aisle: 'Dairy & Eggs', checked: false, order: 0 }],
    };
    const text = formatPlainText(parsed);
    expect(text).toContain('Quick');
    expect(text).not.toContain('DAIRY & EGGS');
    expect(text).toContain('[ ] Milk');
  });
});
