import { describe, it, expect } from 'vitest';
import { renderListHTML, relativeTime } from '../functions/list/[id].js';

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

describe('shared grocery list page — security', () => {
  it('HTML-escapes a malicious item name (no script injection)', () => {
    const html = renderListHTML({
      title: 'Weekend Shop',
      items: [{ name: '<script>alert(1)</script>', quantity: '', unit: '', checked: false, outOfStock: false, substitution: '' }],
    });
    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).toContain('&lt;script&gt;');
  });

  it('escapes a malicious substitution note', () => {
    const html = renderListHTML({
      title: 'Taco Night',
      items: [{ name: 'milk', quantity: '1', unit: 'cup', checked: false, outOfStock: false, substitution: '"><img src=x onerror=alert(1)>' }],
    });
    expect(html).not.toContain('<img src=x');
    expect(html).toContain('&lt;img');
  });

  it('neutralizes a profane list title via moderation', () => {
    const html = renderListHTML({ title: 'fuck this list', items: [] });
    expect(html.toLowerCase()).not.toContain('fuck');
    expect(html).toContain('Grocery List'); // fallback title
  });

  it('renders a clean list with aisle headers, check state, and swaps', () => {
    const html = renderListHTML({
      title: 'Sunday Shop',
      items: [
        { name: 'apples', quantity: '6', unit: '', aisle: 'Produce', checked: true, outOfStock: false, substitution: '' },
        { name: 'buttermilk', quantity: '1', unit: 'cup', aisle: 'Dairy & Eggs', checked: false, outOfStock: false, substitution: '1 cup milk + 1 tbsp lemon juice' },
      ],
    });
    expect(html).toContain('Sunday Shop');
    expect(html).toContain('Produce');
    expect(html).toContain('Dairy &amp; Eggs');
    expect(html).toContain('Apples'); // title-cased to match the iOS row
    expect(html).toContain('→ 1 cup milk + 1 tbsp lemon juice');
    expect(html).toContain('1 of 2 still to buy');
    expect(html).toContain('li class="item checked"'); // apples is checked
  });

  it('shows the all-set state when everything is checked', () => {
    const html = renderListHTML({
      title: 'Done Shop',
      items: [{ name: 'salt', quantity: '', unit: '', checked: true, outOfStock: false, substitution: '' }],
    });
    expect(html).toContain('All set');
    expect(html).toContain('progress done');
  });
});

describe('shared grocery list page — display', () => {
  const items = [
    { name: 'baby spinach', quantity: '1', unit: 'bag', aisle: 'Produce', checked: false, outOfStock: false, substitution: '' },
    { name: 'whole milk', quantity: '1', unit: 'gallon', aisle: 'Dairy & Eggs', checked: true, outOfStock: false, substitution: '' },
  ];

  it('title-cases item names the way the iOS row does', () => {
    const html = renderListHTML({ title: 'Shop', items });
    expect(html).toContain('Baby Spinach');
    expect(html).toContain('Whole Milk');
    expect(html).not.toContain('>baby spinach');
  });

  it('uses the numeric App Store id for the Smart App Banner', () => {
    const html = renderListHTML({ title: 'Shop', items });
    // A bundle id here is silently ignored by Safari — the banner must be
    // the numeric ASC app id.
    expect(html).toContain('content="app-id=6762527184"');
    expect(html).not.toContain('app-id=com.llamascookbook.app');
  });

  it('emits absolute og:image / og:url for link previews', () => {
    const html = renderListHTML(
      { title: 'Shop', items },
      { origin: 'https://llamascookbook.pages.dev', url: 'https://llamascookbook.pages.dev/list/abc123' }
    );
    expect(html).toContain('property="og:image" content="https://llamascookbook.pages.dev/llama-icon.png"');
    expect(html).toContain('property="og:url" content="https://llamascookbook.pages.dev/list/abc123"');
    expect(html).toContain('rel="canonical" href="https://llamascookbook.pages.dev/list/abc123"');
  });

  it('shows who shared the list and how fresh it is', () => {
    const now = Date.parse('2026-08-08T12:00:00Z');
    const html = renderListHTML(
      { title: 'Shop', items, ownerName: 'Dad', updatedAt: now - 5 * MINUTE },
      { now }
    );
    expect(html).toContain('Shared by Dad');
    expect(html).toContain('updated 5 min ago');
  });

  it('screens and escapes a hostile ownerName', () => {
    const now = Date.parse('2026-08-08T12:00:00Z');
    const html = renderListHTML(
      { title: 'Shop', items, ownerName: '<img src=x onerror=alert(1)>', updatedAt: now },
      { now }
    );
    expect(html).not.toContain('<img src=x');
    expect(html).toContain('&lt;img');
  });

  it('omits the subhead entirely on a record with no provenance fields', () => {
    const html = renderListHTML({ title: 'Shop', items });
    expect(html).not.toContain('class="subhead"');
  });

  it('nests only block-level elements inside the row body', () => {
    const html = renderListHTML({
      title: 'Shop',
      items: [{ name: 'milk', quantity: '', unit: '', checked: false, outOfStock: true, substitution: '' }],
    });
    // The note is a <div>; its parent must not be a <span> (invalid markup).
    expect(html).toContain('<div class="body">');
    expect(html).not.toContain('<span class="body">');
  });

  it('marks the check glyph decorative and states the status for screen readers', () => {
    const html = renderListHTML({ title: 'Shop', items });
    expect(html).toContain('aria-hidden="true"');
    expect(html).toContain('<span class="sr">In cart: </span>');
    expect(html).toContain('<span class="sr">To buy: </span>');
  });

  it('labels each aisle section for assistive tech when aisles are shown', () => {
    const html = renderListHTML({ title: 'Shop', items });
    expect(html).toContain('<section aria-labelledby="aisle-0">');
    expect(html).toContain('<h2 class="aisle" id="aisle-0">');
  });
});

describe('relativeTime', () => {
  const now = Date.parse('2026-08-08T12:00:00Z');

  it('buckets recent edits', () => {
    expect(relativeTime(now - 10_000, now)).toBe('updated just now');
    expect(relativeTime(now - 5 * MINUTE, now)).toBe('updated 5 min ago');
    expect(relativeTime(now - 3 * HOUR, now)).toBe('updated 3 hours ago');
    expect(relativeTime(now - HOUR, now)).toBe('updated 1 hour ago');
    expect(relativeTime(now - 2 * DAY, now)).toBe('updated 2 days ago');
    expect(relativeTime(now - DAY, now)).toBe('updated 1 day ago');
  });

  it('falls back to an absolute date past a week', () => {
    expect(relativeTime(Date.parse('2026-07-04T12:00:00Z'), now)).toBe('updated Jul 4');
  });

  it('tolerates small clock skew but ignores wildly future timestamps', () => {
    expect(relativeTime(now + 30_000, now)).toBe('updated just now');
    expect(relativeTime(now + 10 * DAY, now)).toBe('');
  });

  it('returns empty for a missing or unusable timestamp', () => {
    expect(relativeTime(null, now)).toBe('');
    expect(relativeTime(undefined, now)).toBe('');
    expect(relativeTime(NaN, now)).toBe('');
  });
});
