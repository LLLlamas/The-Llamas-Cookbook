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
    title: { value: title },
    payload: { value: JSON.stringify(items) },
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
      { name: 'Tomatoes', qty: '3', unit: '', aisle: 'Produce', needed: true, order: 0 },
      { name: 'Ground beef', qty: '1', unit: 'lb', aisle: 'Meat & Seafood', needed: true, order: 1 },
    ]);
    const parsed = parseGroceryRecord(record);
    expect(parsed.title).toBe('Taco Night');
    expect(parsed.items).toHaveLength(2);
    expect(parsed.items[0]).toMatchObject({ name: 'Tomatoes', quantity: '3', aisle: 'Produce', needed: true, checked: false });
    expect(parsed.items[1]).toMatchObject({ name: 'Ground beef', unit: 'lb', aisle: 'Meat & Seafood' });
  });

  it('reads per-item check flags by order index', () => {
    const record = makeRecord('List', [
      { name: 'Milk', aisle: 'Dairy & Eggs', order: 0 },
      { name: 'Eggs', aisle: 'Dairy & Eggs', order: 1 },
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
      { name: 'White eggs', aisle: 'Dairy & Eggs', order: 0 },
      { name: 'Butter', aisle: 'Dairy & Eggs', order: 1 },
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

  it('defaults needed to true when omitted, false only when explicit', () => {
    const record = makeRecord('List', [
      { name: 'Salt', aisle: 'Spices', order: 0 },                // omitted
      { name: 'Flour', aisle: 'Pantry & Dry Goods', needed: false, order: 1 },
    ]);
    const parsed = parseGroceryRecord(record);
    expect(parsed.items[0].needed).toBe(true);
    expect(parsed.items[1].needed).toBe(false);
  });

  it('is defensive about a malformed payload', () => {
    const record = { fields: { title: { value: 'Broken' }, payload: { value: '{not json' } } };
    const parsed = parseGroceryRecord(record);
    expect(parsed.title).toBe('Broken');
    expect(parsed.items).toEqual([]);
  });

  it('falls back to a default title and empty items for an empty record', () => {
    const parsed = parseGroceryRecord({ fields: {} });
    expect(parsed.title).toBe('Grocery List');
    expect(parsed.items).toEqual([]);
  });

  it('caps at MAX_ITEMS', () => {
    const many = Array.from({ length: 50 }, (_, i) => ({ name: `Item ${i}`, order: i }));
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
  it('renders aisle headers, check boxes, and omits have-items', () => {
    const parsed = {
      title: 'Weekend Shop',
      items: [
        { name: 'Apples', quantity: '6', unit: '', aisle: 'Produce', needed: true, checked: false, order: 0 },
        { name: 'Milk', quantity: '1', unit: 'gal', aisle: 'Dairy & Eggs', needed: true, checked: true, order: 1 },
        { name: 'Salt', quantity: '', unit: '', aisle: 'Spices', needed: false, checked: false, order: 2 },
      ],
    };
    const text = formatPlainText(parsed);
    expect(text).toContain('Weekend Shop');
    expect(text).toContain('PRODUCE');
    expect(text).toContain('[ ] 6 Apples');
    expect(text).toContain('[x] 1 gal Milk');
    // "Have" item (Salt, needed:false) is omitted.
    expect(text).not.toContain('Salt');
  });

  it('omits aisle headers when everything is one aisle', () => {
    const parsed = {
      title: 'Quick',
      items: [{ name: 'Milk', quantity: '', unit: '', aisle: 'Dairy & Eggs', needed: true, checked: false, order: 0 }],
    };
    const text = formatPlainText(parsed);
    expect(text).toContain('Quick');
    expect(text).not.toContain('DAIRY & EGGS');
    expect(text).toContain('[ ] Milk');
  });
});
